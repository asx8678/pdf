#!/usr/bin/env bash
# Rebuild the ex_pdfium NIF from the patched source (docs/patches/).
#
# Why: the hex-published precompiled NIF for 0.5.1 predates the project's
# set_page_box patch (docs/patches/ex-pdfium-v0.5.1-box-form-print.patch), so
# gate3 crop tests fail with :nif_not_loaded against the stock binary. The
# patched Rust source (deps/ex_pdfium/native/ex_pdfium/src/lib.rs, applied
# from the patch and fixed to use PdfPageBoundaries::boundaries_mut) must be
# compiled from source AND bundled with the pdfium C library that the
# precompiled package ships.
#
# Steps:
#   1. extract the precompiled NIF (provides libpdfium.dylib + versioned name)
#   2. force a from-source build (EXPDFIUM_BUILD=1)
#   3. graft the source-built lib over the versioned name rustler loads
set -euo pipefail

MIX_ENV="${MIX_ENV:-dev}"

# 1. Precompiled extraction (libpdfium.dylib lives only in this tarball)
echo "==> extracting precompiled NIF (for libpdfium.dylib)"
MIX_ENV=$MIX_ENV mix deps.compile ex_pdfium --force >/dev/null 2>&1 || true

NATIVE_DIR="_build/$MIX_ENV/lib/ex_pdfium/priv/native"
if [ ! -f "$NATIVE_DIR/libpdfium.dylib" ]; then
  echo "error: libpdfium.dylib not found after precompiled extraction" >&2
  exit 1
fi

# 2. From-source build (patch lives in the deps checkout; needs boundaries_mut,
#    see docs/patches/ex-pdfium-v0.5.1-box-form-print.patch)
echo "==> building ex_pdfium from source (EXPDFIUM_BUILD=1)"
EXPDFIUM_BUILD=1 MIX_ENV=$MIX_ENV mix deps.compile ex_pdfium --force >/dev/null 2>&1

SRC_LIB="deps/ex_pdfium/native/ex_pdfium/target/release/libex_pdfium.dylib"
if [ ! -f "$SRC_LIB" ]; then
  echo "error: source-built NIF not found at $SRC_LIB" >&2
  exit 1
fi

# 3. Graft: rustler_precompiled loads the VERSIONED name; the source build only
#    produces ex_pdfium.so. Copy the source lib onto both names, keeping the
#    precompiled libpdfium.dylib beside it.
echo "==> grafting source-built NIF onto the versioned name"
VERSIONED=$(ls "$NATIVE_DIR"/libex_pdfium-*.so 2>/dev/null | head -1 || true)
if [ -n "$VERSIONED" ]; then
  cp "$SRC_LIB" "$VERSIONED"
fi
cp "$SRC_LIB" "$NATIVE_DIR/ex_pdfium.so"

echo "==> done. Verify: MIX_ENV=$MIX_ENV mix test test/quire/gate3_test.exs"
