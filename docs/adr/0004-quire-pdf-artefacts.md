# ADR 0004 — `Quire.Pdf` NIF artefacts: build from source

- **Status:** accepted. Supersedes, in part, the first Consequence of
  [ADR 0001](0001-native-nif-artefacts.md) — see the amendment recorded there.
- **Date:** 2026-07-29
- **Tasks:** pdf-4ymp (P1), from pdf-ysy3 item 4. Consequence of
  [ADR 0003](0003-pdfium-capability-map.md) D1.
- **Spec:** plan3.md §3.3, §3.6.1, §7.3, §12.1, Appendix A, Appendix B.1

## Context

[ADR 0003](0003-pdfium-capability-map.md) D1 introduced `native/quire_pdf`, a
first-party Rustler NIF over `lopdf` 0.44.0, because PDFium's public API has no
outline-write path at all (seven `FPDFBookmark_*` symbols, all getters). That
decision was correct and is not reopened here. This ADR settles the question it
created: **how does that NIF reach a developer's machine?**

As built, it does not reach them — it is *made* on them.
`lib/quire/pdf/native.ex:22` is `use Rustler, otp_app: :quire, crate: :quire_pdf`,
which compiles the crate during that module's own compilation on every
`mix compile`. `mise.toml` therefore pins `rust = "1.91"`, because rustler
0.38.0's manifest declares `rust-version = "1.91"` and cargo hard-refuses below
it with no override.

That makes a Rust toolchain a hard prerequisite for every developer, every CI
job and every container build. It is the exact property T-003 deliberately
preserved for `ex_pdfium` by choosing `rustler_precompiled`, and it is now
*stricter* than a mere preference: `mise.toml` pins a floor rather than offering
Rust as a fallback. ADR 0001's headline consequence — "No developer needs a Rust
toolchain on the happy path" — is false as written, and the two documents have
to stop contradicting each other.

## Measurements

Apple M4, 10 cores, macOS 27 (Darwin 27.0.0), OTP 28.1, Elixir 1.20.2-otp-28,
`rustc 1.91.1 (ed61e7d7e 2025-11-07)`, `cargo 1.91.1`. All builds are release
mode: `Rustler.Compiler.Config` defaults `mode: :release`
(deps/rustler/lib/rustler/compiler/config.ex:25,39) and there is no Mix.env
override, so a dev build is an optimised build.

| What | Measured |
|---|---|
| `quire_pdf.so` | **1 343 152 bytes (1.28 MiB)**, Mach-O 64-bit arm64, adhoc/linker-signed |
| `otool -L` | `/usr/lib/libiconv.2.dylib`, `/usr/lib/libSystem.B.dylib`. Nothing from `/opt/homebrew`, no `LC_RPATH`, no vendored library |
| Cold `cargo build --release` (`target/` removed, `~/.cargo` warm) | **18.38 s** wall (cargo self-reports 18.29 s) |
| Cold `mix compile --force` (`target/` removed) | **18.56 s** wall, incl. 28 `.ex` files |
| Cold with **empty `CARGO_HOME`** — the clean-second-machine case | **23.16 s** wall; 40 MB downloaded |
| Warm `mix compile --force` (28 `.ex` files, cargo a no-op) | **1.47 s** wall |
| Incremental after a one-line edit to `src/lib.rs` | **2.15 s** wall |
| No-op `mix compile` | **0.93 s** wall; cargo not invoked |
| Dependency graph | 62 packages resolved; 87 `cargo tree` edges |
| `native/quire_pdf/target/` after a release build | 116 MB |
| `rust 1.91.1` toolchain on disk (`~/.rustup/toolchains/`) | 1.2 GB (download size not measured) |
| Crate today | 582 lines, 8 NIFs, all `#[rustler::nif(schedule = "DirtyCpu")]` |

Two behaviours worth recording because they are not obvious:

- **`touch` does not trigger a rebuild.** `touch native/quire_pdf/src/lib.rs`
  followed by `mix compile` recompiles nothing and does not invoke cargo, even
  with `target/` deleted. Only a *content* change does. This is consistent with
  Elixir 1.19+ checking `@external_resource` staleness by digest rather than
  mtime, and it is why the everyday cost of this decision is genuinely zero
  rather than merely small.
- **`cargo clean` alone leaves a stale artefact in place.** Because of the
  above, removing `target/` does not make Mix rebuild; `_build/dev/lib/quire/priv/native/quire_pdf.so`
  survives untouched. To force a real cold build use `mix compile --force`.

`Cargo.lock` is committed; `/native/*/target/` and `/priv/native/` are
gitignored (.gitignore:50-52). The reproducibility contract of §3.6.2 holds.

## Options considered

**(a) Build from source, as now.** Zero release infrastructure: no matrix, no
checksum file, no signing, no hosting, no version-bump ritual. The NIF can never
be out of step with the Elixir stubs. Cost: Rust >= 1.91 for every developer, CI
job and container build.

**(b) `rustler_precompiled` with our own release matrix.** Nominally restores
"no Rust toolchain". Cost: Quire's *first* CI workflow (there is no `.github/`
in the repo at all today), four target artefacts published to Quire's own GitHub
releases, and `checksum-Elixir.Quire.Pdf.Native.exs` carrying the ordering
hazard `ex_pdfium` documents at deps/ex_pdfium/lib/ex_pdfium/native.ex:6-14.
Cheaper here than for `ex_pdfium` in one respect: 1.28 MiB self-contained, with
no 5.5 MB vendored `libpdfium` to ship (ADR 0003, D4).

## Decision

**(a). `native/quire_pdf` is built from source. Rust >= 1.91 is a declared,
first-class build prerequisite of this project, not a fallback.**

### Why (b) does not buy what it appears to buy

`rustler_precompiled` solves one problem: *a published Hex library whose
downstream consumers have no toolchain*. Quire has no downstream consumers. It
is an application; its only consumers are its own developers and its own CI,
and both already run `mise install` at bootstrap step 5 (§3.6.1), which installs
Rust. `ex_pdfium`'s own `force_build: System.get_env("EXPDFIUM_BUILD") in ["1","true"]`
escape hatch exists precisely because *maintainers* must still build from
source. Quire would need the same flag for dev and test — so Quire developers
would build from source anyway, and CI would build from source four times
instead of once.

### Why the toolchain requirement is unavoidable regardless

§12.1's `beforeBuildCommand` runs `MIX_ENV=prod mix release` from inside a cargo
build; `src-tauri/` is a Rust crate. T-173 states it outright: "Rust comes from
mise, already present since Phase 0 — do not add rustup separately, and do not
let Tauri's installer script add a second toolchain." Precompiling `quire_pdf`
cannot produce a toolchain-free packaging machine, because Tauri has already
spent that budget. The plan's own architecture concedes the point.

### Why the measured cost is acceptable

18.4 s cold, 23.2 s on a genuinely clean machine including the download of all
62 crates, 2.15 s after a Rust edit, and **zero** in normal work. Set against a
Phase-0 bootstrap that builds OTP 28 from source with kerl (§3.6.3), this is
noise.

### Why (b) is worse against Gate 0, not better

Gate 0 requires `mise run doctor` green on a clean checkout on a second machine
"with no manual intervention" (T-196). Under (a) there is no manual step to
eliminate: `mise install` installs rust 1.91.1, `mise-tasks/doctor` already
asserts `rustc --version` is 1.91.x, and `mise run setup` does the rest. What
(a) costs Gate 0 is 1.2 GB of disk and ~23 s of wall clock. Under (b), a fresh
clone at a tag whose checksum file has not yet been regenerated **cannot build
at all** — that is a new clean-machine failure mode, introduced in the name of
clean-machine friendliness.

### Why the matrix would be three-quarters dead weight

v1 is "Web-first Phoenix app running natively on macOS (Apple Silicon)"
(plan3.md:11), and §12 calls Windows and Linux "the two platforms you have not
been developing on." A four-target matrix today publishes
`x86_64-apple-darwin`, `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu`
binaries that nothing runs and no test exercises.

### Why the ordering hazard lands hardest on this crate specifically

`ex_pdfium`'s own note is explicit: the checksum file is regenerated *after* the
release workflow uploads the artefacts, so every NIF change is tag → release →
`mix rustler_precompiled.download` → commit checksum. `native/quire_pdf` is 582
lines and 8 NIFs today, but ADR 0003 assigns it `Quire.Pdf.Outline`,
`Quire.PdfA`, `Quire.SecurityHandler`, `Quire.Pades` and `Quire.Pdf.AcroForm`
— the last being appearance-stream generation, i.e. font metrics and
content-stream emission. This crate will churn hard across Phases 2, 4 and 8.
Five steps per Rust edit versus 2.15 s is not a close call.

### Why "cannot be out of step" is load-bearing

Under (b) with `force_build` off, a developer editing `src/lib.rs` silently gets
the *downloaded* `.so`. The stubs in `lib/quire/pdf/native.ex` would then name
exports the loaded library does not have — a `load_nif` failure or a
`:nif_not_loaded` raise at runtime, from a source tree that looks entirely
correct. Under (a) that state is unrepresentable.

### The asymmetry, honestly read

`quire_pdf` is cheaper to precompile than `ex_pdfium` — 1.28 MiB, self-contained,
no 5.5 MB vendored `libpdfium`. It is also *cheaper to build*: 18.4 s here
against the 13.85 s ADR 0003 measured for a from-source `ex_pdfium` NIF, which
additionally has to acquire `libpdfium`, and that acquisition is what made
precompilation worth paying for there. Small artefact **plus** fast build
**plus** no vendored native library is an argument for source builds, not
against them.

## Consequences

- **Rust >= 1.91 is a hard prerequisite of Quire**, on the happy path, for
  everyone. `mise.toml`'s `rust = "1.91"` is a floor set by rustler 0.38.0's
  declared `rust-version`, not by `lopdf` (which needs only 1.88). It is
  installed by `mise install` at §3.6.1 step 5 and asserted by
  `mise-tasks/doctor`. **ADR 0001's first Consequence is amended accordingly.**
- **plan3.md Appendix B.1 is wrong** and must be corrected: it specifies
  `rust = "1.90"` described as "NIF fallback builds; Tauri in Phase 13". Both
  halves are now false — the pin is 1.91 and the builds are not a fallback.
- **plan3.md Appendix A's Rustler row is wrong** (line 222): "Precompiled
  artefacts are preferred; Rust is needed if a darwin-arm64 artefact is
  missing." Rust is needed unconditionally. That row also still cites "the
  Tesseract NIF", which ADR 0001 voided.
- **CI must cache `~/.cargo` and `native/*/target/`** when a workflow first
  exists, which reduces the recurring cost from ~23 s to the ~2 s warm figure.
  Every CI image and container carries a 1.2 GB toolchain; this is the price.
- **A rustler or lopdf MSRV bump is a fleet-wide event.** Moving `mise.toml`
  forces every machine to fetch a new ~1.2 GB toolchain. This has already
  happened once (1.90 → 1.91). Treat an MSRV-raising rustler bump as a
  deliberate decision, not a routine `mix deps.update`.
- **No release infrastructure, no signing, no checksum file, no artefact
  hosting, and no version-bump ritual** are created by this project. `Cargo.lock`
  plus `mise.toml` remain the whole contract for this crate.
- **Gatekeeper is not implicated either way.** The built `.so` is
  adhoc/linker-signed and carries no `com.apple.quarantine`, so neither §3.6.6
  nor `mise run assets:resign` applies to it — the same finding ADR 0001
  recorded for `ex_pdfium`'s downloaded binaries.
- **§12.1's `otool -L` check passes today.** `quire_pdf.so` links only
  `/usr/lib/libiconv.2.dylib` and `/usr/lib/libSystem.B.dylib`. Nothing to
  bundle, nothing to `install_name_tool`. Re-verify at T-181.

## Revisit trigger

One, and it is concrete: **if `Quire.Pdf` is extracted into a standalone Hex
package.** A general `lopdf` binding is genuinely reusable, and the moment it
has consumers who are not us, `rustler_precompiled` becomes the right answer —
inside that package, where toolchain-less consumers actually exist. The decision
flips there, not here. Absent that, this ADR stands through Phase 13.

Note what is explicitly **not** a revisit trigger: cold CI build time. The
answer to that is `actions/cache`, not a release matrix.
