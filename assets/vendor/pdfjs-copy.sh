#!/usr/bin/env bash
# Copy pdf.js runtime assets into priv/static/vendor/pdfjs/
# Run from project root: bash assets/vendor/pdfjs-copy.sh
set -euo pipefail

SRC="assets/node_modules/pdfjs-dist"
DST="priv/static/vendor/pdfjs"

mkdir -p "$DST"

# Copy the ESM viewer module and worker
cp "$SRC/web/pdf_viewer.mjs" "$DST/"
cp "$SRC/build/pdf.mjs" "$DST/"
cp "$SRC/build/pdf.worker.mjs" "$DST/"
cp "$SRC/build/pdf.sandbox.mjs" "$DST/"

# Copy resource directories needed for CJK, JPEG2000 and font rendering
# plan3.md §3.2 lines 251-254: missing these produces silent blank pages
for dir in cmaps standard_fonts iccs wasm; do
  if [ -d "$SRC/$dir" ]; then
    mkdir -p "$DST/$dir"
    cp -r "$SRC/$dir/"* "$DST/$dir/"
  fi
done

echo "pdf.js assets copied to $DST"
ls -la "$DST/"
