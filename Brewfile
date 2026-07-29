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
cask "chromium"

# Tesseract is NOT enabled yet. Appendix B.2 makes it conditional on the T-019
# ADR (pdf-9qh) choosing a system Tesseract over a vendored or static one, and
# pdf-tuj (P0) has to first establish whether an in-process Tesseract NIF exists
# at all. Uncomment both lines only when that ADR lands.
#
# `tesseract-lang` is ~1.5 GB; if that is too much, drop it and let T-141
# download language packs on demand.
#
# brew "tesseract"
# brew "tesseract-lang"
