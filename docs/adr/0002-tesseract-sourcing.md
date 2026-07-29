# ADR 0002 — OCR engine and Tesseract sourcing

- **Status:** accepted for v1 (local development on the §3.6 target). Revisit at T-180.
- **Date:** 2026-07-29
- **Tasks:** pdf-tuj (P0), T-019 (pdf-9qh), T-022 (pdf-euy)
- **Spec:** plan3.md §3.3, §3.4, §9.10, §12.1, Appendix B.2

## Context

§3.3 rested OCR on a Hex package named `tesseract_elixir`. **That package does
not exist and never has** — `mix hex.info tesseract_elixir` returns "No package
with name tesseract_elixir". Appendix A, Appendix D, T-003 and T-019 all cite
it. Those rows must be deleted, not version-corrected.

§3.4 bans external processes, so a CLI wrapper is not an escape hatch. The
question is therefore which in-process Tesseract NIF to adopt, and how Tesseract
itself is sourced.

## Decision

**Adopt `image_ocr` 0.2.0 (Apache-2.0) over Homebrew Tesseract 5.5.3 +
Leptonica 1.87.0.**

Verified end to end on darwin-arm64: `c_src/image_ocr_nif.cc` compiled against
Homebrew tesseract/leptonica, loaded into a plain OTP 28 / NIF 2.17 arm64 BEAM,
and run over a rendered one-line fixture. `recognize_nif` returned
`{:ok, "Hello Quire OCR\n"}`; `recognize_with_boxes_nif` returned per-word
confidences (95.71 / 95.97 / 96.96) with bounding boxes — which is exactly what
§9.10 and T-142 require, in-process, with no subprocess. Both recognition entry
points declare `ERL_NIF_DIRTY_JOB_CPU_BOUND`.

This is a **sanctioned** outcome, not a compromise: §3.4 already lists "a system
C library required by a NIF (e.g. Tesseract + tessdata via Homebrew if the NIF
does not vendor it)" as allowed *with an ADR*. This is that ADR.

### Why not the alternatives

- **Vendored / statically linked.** This is what §12 ultimately wants, and the
  tooling is already present (`elixir_make` 0.10.0 ships `elixir_make.precompile`;
  `cc_precompiler` arrives via vix). But a genuinely redistributable artefact
  needs a from-source Tesseract + Leptonica build covering the whole
  `pkg-config --static` closure — libarchive, libcurl, libpng, jpeg-turbo,
  openjpeg, giflib, libtiff, webp, zlib — across four target triples with
  published checksums. That is T-180's work. Blocking Phase 0 on a
  redistribution problem that first bites in Phase 13 inverts the plan's own
  sequencing.
- **`tesserax` 0.1.5.** Disqualified on two independent grounds: it reports **no
  per-word confidence at all**, which §9.10 requires; and it has a one-byte heap
  overflow on every recognition. (A third objection — "does not build on
  darwin-arm64" — is weaker than it looks: it builds once two undocumented
  environment variables are exported. That is a packaging bug, not a
  disqualifier. The first two settle it.)
- **Write our own Rustler binding.** Buys nothing here. Rust does not make
  libtesseract's C++ ABI or its sourcing problem disappear — the mainstream
  crates are themselves `-sys` bindings against the *system* library. This is
  the vendored option's cost plus writing the binding.
- **Cut OCR from v1.** Unjustifiable when a working Apache-2.0 in-process NIF
  exists that returns exactly what the spec asks for.

## Consequences

### The Brewfile needs `pkgconf`, and it is a Gate 0 blocker

`image_ocr`'s Makefile shells out to `pkg-config` to locate Tesseract. Xcode CLT
does **not** ship pkg-config, and pkgconf is a *build-only* dependency of the
tesseract formula — `brew deps --include-build tesseract` lists it,
`brew deps tesseract` does not — so pouring the bottle does not install it.

On a clean second machine the build dies with
`ERROR: image_ocr requires tesseract >= 5.0.0 (found none)`. That is precisely
the machine Gate 0 tests. `brew "pkgconf"` is therefore required, not optional.

### `brew "tesseract"` is load-bearing for auto-rotate, not just for the libraries

§9.10 promises automatic page rotation. That needs `osd.traineddata`, which ships
with the **base** `tesseract` formula, not with `tesseract-lang`. Do not later
swap `brew "tesseract"` for a libraries-only source without also seeding `osd`.

### `tesseract-lang` (~1.5 GB) can be dropped

`image_ocr` vendors `eng` tessdata_fast in `priv/` and fetches further packs on
demand, so T-141 can install language packs without the 1.5 GB up-front cost.
`osd` must still be available — from the base formula or seeded explicitly.

### Redistribution is deferred, and the trigger is named

`otool -L` on the built NIF shows live links into `/opt/homebrew`. A NIF linking
`/opt/homebrew` **cannot ship in a distributed `.app`** — §12.1 step 8 is
explicit. The deferral is honest only because the trigger is named:

1. **T-180** (native-library redistribution) — the first point it actually
   breaks. This is the primary trigger. Note T-180 is larger than the plan's
   "budget more than a day": the transitive dylib closure is 14 libraries, and
   the exit is a per-triple precompile matrix, not a static link on macOS.
2. **The first build on a non-macOS host.** `image_ocr` does not build on
   Windows at all, so **T-183 is blocked independently of T-180** — a static
   link on macOS does not make the Makefile build on Windows.
3. A Tesseract 6 soname bump landing in Homebrew.
4. `image_ocr` going unmaintained or archived.
5. Gate 0 / T-196 failing on a second machine.

### Maturity is a live risk with no register entry

`image_ocr` has 2 releases, 160 all-time downloads and 3 GitHub stars. The
maintainer is Kip Cole (author of `image` and the ex_cldr suite), which is real
credibility, but this specific package has near-zero field exposure for
something load-bearing. Appendix C has no R-## covering it. The `== 0.2.0` exact
pin is deliberate; the package is ~290 lines of C++ and forkable if abandoned.

### T-022 caveat

`init_nif` runs on a **normal** scheduler while loading a ~4 MB traineddata
file. Moving it into a pool worker does not fix that — the pool's
`init_worker/1` is itself a synchronous normal-scheduler call. T-022 must time
`init_nif` against the §14.1 budget; if it exceeds it, the fix is upstream
(`ERL_NIF_DIRTY_JOB_CPU_BOUND` on `init_nif`, a one-line change).

## Scope

This ADR settles the *choice*. Pinning `{:image_ocr, "== 0.2.0"}` in `mix.exs`
and wiring `Quire.Ocr.Tesseract` remains T-019 (pdf-9qh) — the dependency is
deliberately still commented out in `mix.exs`, because adding it makes a
Homebrew Tesseract a hard build prerequisite for every developer, and that
should land with the integration rather than ahead of it.
