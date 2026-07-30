# Quire system dependencies — plan3.md Appendix B.2, §3.6.2.
#
# Deliberately tiny; that is the point of this architecture. mise owns every
# language runtime, so nothing here is a compiler or an interpreter.
#
# Install with `brew bundle --no-upgrade` so an unrelated `brew upgrade` does
# not silently move a native library underneath you. `mise run doctor` is what
# catches it when it happens anyway.
#
# NOTHING ELSE MAY BE ADDED TO THIS FILE WITHOUT AN ADR (§3.4).

brew "postgresql@18" # Database (18.4). Started with `brew services start postgresql@18`.
brew "openssl@3"     # kerl needs it to build OTP crypto — see KERL_CONFIGURE_OPTIONS in mise.toml.
brew "autoconf"      # kerl.

# URL→PDF and Office→PDF renderer, spawned on demand by chromic_pdf (T-072).
# Reusing an already-installed Chrome is equally fine — either way the path is
# explicit config (`config :chromic_pdf, chrome_executable:`), never discovery
# (§3.6.6). Set CHROME_EXECUTABLE in .mise.local.toml if you reuse Chrome and
# want to skip this cask.
cask "chromium", args: { "no-quarantine": true }

# OCR. docs/adr/0002-tesseract-sourcing.md settled this: `image_ocr` 0.2.0 links
# against a Homebrew Tesseract, which §3.4 permits for a NIF's system C library
# given an ADR. Revisit at T-180 — a NIF linking /opt/homebrew cannot ship in a
# distributed .app (§12.1 step 8).
#
# The base formula is load-bearing for more than the shared libraries: it also
# supplies osd.traineddata, which §9.10's automatic page rotation needs. Do not
# swap it for a libraries-only source without seeding `osd` some other way.
brew "tesseract"

# REQUIRED, and easy to miss. image_ocr's Makefile locates Tesseract with
# pkg-config. Xcode CLT does not ship it, and pkgconf is a *build-only*
# dependency of the tesseract formula (`brew deps --include-build tesseract`
# lists it; `brew deps tesseract` does not), so pouring the bottle does NOT
# install it. Without this line a clean second machine — exactly what Gate 0
# tests — fails with "image_ocr requires tesseract >= 5.0.0 (found none)".
brew "pkgconf"

# `tesseract-lang` (~1.5 GB) is deliberately NOT here: image_ocr vendors `eng`
# tessdata_fast in priv/ and T-141 fetches further packs on demand.
