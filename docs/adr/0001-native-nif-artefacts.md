# ADR 0001 — Native NIF artefacts on Apple Silicon

- **Status:** accepted for `ex_pdfium` and `vix`. OCR is settled separately in
  [ADR 0002](0002-tesseract-sourcing.md).
- **Date:** 2026-07-29
- **Tasks:** T-003 (pdf-86r). T-021 (pdf-n2g) and T-022 (pdf-euy) record their
  dirty-scheduler outcomes here. T-019 (pdf-9qh) will append the OCR decision.
- **Spec:** plan3.md §3.3, §7.3, Appendix A, Appendix D

## Context

§7.3 requires that `mix deps.compile ex_pdfium` be run on a clean `_build` and
that the outcome — precompiled artefact downloaded, or built from source — be
written down. The distinction matters: a source build makes a Rust toolchain a
hard prerequisite for every developer and puts PDFium's own build system on the
critical path, which is a materially different project from the one the plan
describes.

## Decision and observed outcome

### `ex_pdfium == 0.5.1` — downloads a precompiled artefact. No Rust required.

Observed on this machine (macOS 27, arm64, OTP 28, Elixir 1.20.2) after
`mix deps.clean ex_pdfium --build`:

```
$ mix deps.compile ex_pdfium
==> ex_pdfium
Compiling 6 files (.ex)
[debug] Copying NIF from cache and extracting to
        _build/dev/lib/ex_pdfium/priv/native/
        libex_pdfium-v0.5.1-nif-2.15-aarch64-apple-darwin.so.tar.gz
Generated ex_pdfium app
```

Elapsed under one second. No `cargo`, `rustc` or `cc` invocation. What landed:

| File | Type |
|---|---|
| `libex_pdfium-v0.5.1-nif-2.15-aarch64-apple-darwin.so` | Mach-O 64-bit dynamically linked shared library arm64 |
| `libpdfium.dylib` | Mach-O 64-bit dynamically linked shared library arm64 |

The NIF loads in-process and answers: `ExPdfium.pdfium_version()` returns
`"pdfium loaded"`. No subprocess is spawned, satisfying §3.4.

Mechanism, from `lib/ex_pdfium/native.ex`: `use RustlerPrecompiled` with
`targets: ~w(aarch64-apple-darwin x86_64-apple-darwin x86_64-unknown-linux-gnu
aarch64-unknown-linux-gnu)` and `force_build:` gated on `EXPDFIUM_BUILD` being
`"1"`/`"true"` — so **download is the default path and a source build is
opt-in**. The upstream asset's SHA-256 was verified independently against
`checksum-Elixir.ExPdfium.Native.exs` and matches
`d874bbef8f2c6f76825d1ed63b3d36127a79ba9c3cf665f3976ca3344b313073`.

Both binaries are adhoc/linker-signed and carry no `com.apple.quarantine`
attribute, so the §3.6.6 Gatekeeper problem — and the `mise run assets:resign`
workaround built in T-002 — **do not apply to this dependency**.

`rustler_precompiled` is therefore declared explicitly at `~> 0.8.4` rather than
left to float. It is the component that performs the download; ex_pdfium asks
for `~> 0.8`, which would float to 0.9.0, a line it was not developed against.
`rustler` stays at `~> 0.38, runtime: false` purely as the `EXPDFIUM_BUILD=1`
fallback and for Tauri in §12.

### T-021 dirty schedulers — satisfied by construction

All 45 `#[rustler::nif]` attributes in `native/ex_pdfium/src/lib.rs` are
`#[rustler::nif(schedule = "DirtyCpu")]`; there are no exceptions. (45 is the
NIF count. The Elixir surface is 51 distinct public function names across 59
`def` clauses — an earlier draft of this ADR conflated the two.) The package's
own module doc states the intent: "pdfium work is synchronous and CPU-heavy ->
every NIF is DirtyCpu." Resource teardown is handed to a cleanup thread so a
GC-driven close cannot block a normal scheduler. T-021's benchmark should still
run, but its outcome is not in doubt.

**Newly discovered, not in the plan:** ex_pdfium holds a process-wide
`PDFIUM_LOCK` mutex that serialises *every* PDFium call. §7.2's concurrency model
does not account for this — see the follow-up issue.

### `vix == 0.40.0` — precompiled, but statically combined

`vix` ships `vix-nif-2.17-aarch64-apple-darwin-0.40.0.tar.gz`. The NIF links
`@rpath/libvips-cpp.8.18.3.dylib` under `LC_RPATH @loader_path/precompiled_libvips/lib`
and touches nothing in `/opt/homebrew` — libvips travels inside the artefact.
Pinned exactly for the same reason as ex_pdfium: a minor bump swaps a bundled
native library.

**This has a licensing consequence the plan gets wrong** — see the follow-up
issue on LGPLv3. The bundled dylib statically incorporates eight LGPL-3.0
libraries plus MPL-2.0 cairo; plan3.md's claim that vix is "LGPL-2.1,
dynamically linked" is inaccurate on both counts, and §12's Tauri packaging
inherits obligations the plan currently assumes away.

### OCR — decided in [ADR 0002](0002-tesseract-sourcing.md)

`image_ocr` 0.2.0 over Homebrew Tesseract, revisited at T-180. The evidence that
led there is kept below.

### `tesseract_elixir` does not exist

`tesseract_elixir`, named in Appendix A, Appendix D, T-003 and T-019, **has never
been published to Hex**. Those rows must be deleted, not version-corrected.

Of the three Tesseract bindings that do exist, only two are in-process NIFs:
`image_ocr` 0.2.0 (Apache-2.0, C++ NIF) and `tesserax` 0.1.5 (MIT, C NIF). The
highest-download package, `tesseract_ocr`, shells out via
`System.cmd("tesseract", ...)` and is disqualified by §3.4.

`image_ocr` was verified end to end: compiled against Homebrew tesseract 5.5.3 +
leptonica 1.87.0, loaded into an OTP 28 arm64 BEAM, and run over a one-line
fixture, returning per-word confidences (95.71, 95.97, 96.96) — which is
pdf-tuj's acceptance criterion, met with real output. Both recognition entry
points declare `ERL_NIF_DIRTY_JOB_CPU_BOUND`, pre-satisfying T-022.

It is **not pinned** because it ships no precompiled artefact and hard-links to
Homebrew tesseract/leptonica, which forces the answer to the vendored-vs-Homebrew
question the T-019 ADR owes. Its maturity is also a live risk: 2 releases, 160
all-time downloads.

## Consequences

- No developer needs a Rust toolchain on the happy path.
- PDFium is fixed at whatever `ex_pdfium 0.5.1` bundles — **144.0.7543.0**, not
  the 151.0.7891.0 Appendix D claims. Nothing may rely on a post-144 API.
- Appendix A and Appendix D need amending in several places; tracked separately.
