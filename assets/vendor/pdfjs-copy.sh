#!/usr/bin/env bash
# Copy pdf.js runtime assets into priv/static/vendor/pdfjs/
# Run from project root: bash assets/vendor/pdfjs-copy.sh
set -euo pipefail

SRC="assets/node_modules/pdfjs-dist"
DST="priv/static/vendor/pdfjs"

mkdir -p "$DST"

# Copy the ESM viewer module and worker
cp "$SRC/web/pdf_viewer.mjs" "$DST/"
cp "$SRC/web/pdf_viewer.css" "$DST/"
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

# §14.1 budget: "Scroll — 60 fps sustained, ≤ 5 canvases retained".
# pdf.js's in-memory page-view buffer defaults to 10 canvases; shrink it to 4
# so the DOM holds at most the visible page + buffer (~5 canvases). Re-applied
# on every vendor copy, so the patch survives re-vendoring.
if grep -q 'const DEFAULT_CACHE_SIZE = 10;' "$DST/pdf_viewer.mjs"; then
  sed -i '' 's/const DEFAULT_CACHE_SIZE = 10;/const DEFAULT_CACHE_SIZE = 4;/' "$DST/pdf_viewer.mjs"
  echo "patched DEFAULT_CACHE_SIZE 10 -> 4 (§14.1 canvas budget)"
fi

echo "pdf.js assets copied to $DST"
ls -la "$DST/"
