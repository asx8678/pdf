# ADR 0011 — macOS-only desktop build for v1

- **Status:** Accepted
- **Date:** 2026-07-30
- **Tasks:** pdf-xy06
- **Spec:** plan3.md §12, §13 (Gate 13)

## Context

Gate 13 (plan3.md:3064-3066) requires the app to "build and run on all three
platforms" — macOS, Windows and Linux. T-183 (Windows MSI/NSIS) and T-184
(deb + AppImage) exist to produce those builds, but the project has no CI,
no Windows or Linux build host, and a macOS-only development environment.

Three hard constraints block cross-platform builds today:

1. **No cross-compilation.** Tauri does not cross-compile, and `mix release`
   embeds a host-built ERTS into `bundle.resources`, so each platform needs
   its own OTP/Elixir build environment.

2. **macOS-only tooling.** The `Brewfile`, `mise.toml`, and native-library
   paths (`/opt/homebrew`) are macOS-only. No toolchain contract exists for
   Windows (msvc) or Linux (glibc) equivalents.

3. **Missing precompiled NIF artefacts.** Three NIFs
   (`ex_pdfium`/PDFium, `image_ocr`, `vix`) need `rustler_precompiled`
   artefacts for `x86_64-pc-windows-msvc`, `aarch64-pc-windows-msvc`,
   `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu`. T-003 never
   verifies these, and `image_ocr` does not build on Windows at all
   (plan3.md:2405).

These constraints cannot be resolved within the current schedule without
significant investment in cross-platform build infrastructure.

## Decision

**Scope Gate 13 to macOS for v1.** T-183 (Windows) and T-184 (Linux) are
moved to a named post-1.0 phase. The desktop build phase continues to
deliver a native macOS `.app` via Tauri, with real Local Folders, the
localhost auth plug, and the full ribbon.

This is the pragmatic choice: it makes a ~1.5-week phase honest, defers
platform work until the project has a CI host or a concrete cross-platform
customer need, and avoids writing platform-specific code that cannot be
tested.

## Consequences

1. **Gate 13** now reads: "the app builds and runs on **macOS**; opening a
   file from a real folder works; no LiveView or context code changed in this
   phase."

2. **R-11** (webkit2gtk risk) is marked **Deferred** — it only applies to
   Linux, which is post-1.0. The Electron escape hatch remains documented but
   is not a v1 requirement.

3. **§12** language about "the two platforms you have not been developing on"
   is updated to describe one deferred platform (Windows) plus a stretch goal
   (Linux), matching what the project can actually build.

4. **T-183** and **T-184** remain in the issue tracker with a "post-1.0"
   label. Every other Phase 13 task continues as scoped.

5. If a Linux or Windows build is needed before 1.0, the decision is
   revisited. The ADR log captures this as the default position.
