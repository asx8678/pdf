#!/usr/bin/env node
// @ts-check
/**
 * generate_annotation_fixtures.mjs  (T-113, beads pdf-9c3 / Phase 6)
 *
 * Emits one annotated PDF per standard PDF annotation kind into
 * test/fixtures/annotations/, plus manifest.json describing the expected
 * native re-read (type, bounds, /NM, contents) the Acrobat round-trip test
 * (test/quire/annotations/round_trip_test.exs) asserts.
 *
 * We write well-formed PDF source directly with a correct xref table instead
 * of driving @cantoo/pdf-lib's low-level object API. ISO 32000-1 §12.5.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(__dirname, "..", "test", "fixtures", "annotations");

// Byte-accurate PDF string-literal escaping (Latin-1).
function ps(v) {
  return "(" + String(v).replace(/([\\\\()])/g, "\\\\$1").replace(/[\r\n\t]/g, " ") + ")";
}
function rect(x, y, w, h) { return x + " " + y + " " + (x + w) + " " + (y + h); }

// Minimal offset-correct PDF writer. Catalog is the LAST object.
function buildPdf(objects) {
  const N = objects.length;
  let body = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n";
  const off = new Array(N + 1).fill(0);
  for (let i = 0; i < N; i++) {
    const id = i + 1;
    off[id] = Buffer.byteLength(body, "binary");
    const o = objects[i];
    let b = id + " 0 obj\n" + o.dict + "\n";
    if (o.stream !== undefined) b += "stream\n" + o.stream + "\nendstream\n";
    b += "endobj\n";
    body += b;
  }
  const xs = Buffer.byteLength(body, "binary");
  let xref = "xref\n0 " + (N + 1) + "\n0000000000 65535 f \n";
  for (let i = 1; i <= N; i++) xref += String(off[i]).padStart(10, "0") + " 00000 n \n";
  body += xref + "trailer\n<< /Size " + (N + 1) + " /Root 1 0 R >>\nstartxref\n" + xs + "\n%%EOF\n";
  return Buffer.from(body, "binary");
}

function singlePagePdf(opts) {
  const media = opts.mediaBox || [0, 0, 612, 792];
  const content = "BT /F1 12 Tf 72 700 Td (Round trip annotation fixture) Tj ET\n";
  // Object layout mirrors the proven-working hand2 structure:
  //   1 Catalog, 2 Pages, 3 Page, 4 Content, 5 Font, 6.. annotations.
  const objs = [
    { dict: "<< /Type /Catalog /Pages 2 0 R >>" },
    { dict: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>" },
  ];
  let pd = "<< /Type /Page /Parent 2 0 R /MediaBox [" + media.join(" ") + "]";
  if (opts.rotate) pd += " /Rotate " + opts.rotate;
  if (opts.cropBox) pd += " /CropBox [" + opts.cropBox.join(" ") + "]";
  pd += " /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [";
  for (let i = 0; i < opts.annots.length; i++) pd += (6 + i) + " 0 R ";
  pd += "] >>";
  objs.push({ dict: pd });
  objs.push({ dict: "<< /Length " + Buffer.byteLength(content) + " >>", stream: content });
  objs.push({ dict: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>" });
  for (const a of opts.annots) objs.push({ dict: a });
  return buildPdf(objs);
}

// Annotation dict: subtype, /NM, contents, /T author, /C color, extra keys.
function ann(subtype, nm, contents, author, color, extra) {
  let d = "<< /Type /Annot /Subtype " + subtype + " /Rect [" + rect(100, 100, 300, 20) + "]";
  if (extra) d += " " + extra;
  d += " /Contents " + ps(contents) + " /NM (" + nm + ") /T " + ps(author) + " /C [" + color + "] >>";
  return d;
}

const QUAD = "/QuadPoints [100 100 400 100 100 120 400 120]";
const INK = "/InkList [[100 100 200 120 300 160]]";

function mk() { return 1; }
const fixtures = [
  { kind: "highlight", file: "highlight.pdf", subtype: "Highlight", extra: QUAD, nm: "hl-001", contents: "Highlighted passage", author: "Ada", color: "1 1 0", type: "highlight" },
  { kind: "underline", file: "underline.pdf", subtype: "Underline", extra: QUAD, nm: "ul-001", contents: "Underlined passage", author: "Ada", color: "0 0 1", type: "underline" },
  { kind: "strikethrough", file: "strikethrough.pdf", subtype: "StrikeOut", extra: QUAD, nm: "so-001", contents: "Struck passage", author: "Bob", color: "1 0 0", type: "strikeout" },
  { kind: "squiggly", file: "squiggly.pdf", subtype: "Squiggly", extra: QUAD, nm: "sq-001", contents: "Squiggled passage", author: "Bob", color: "0 0 1", type: "squiggly" },
  { kind: "sticky_note", file: "sticky_note.pdf", subtype: "Text", extra: "", nm: "tn-001", contents: "A sticky note", author: "Carol", color: "1 0.84 0", type: "text" },
  { kind: "free_text", file: "free_text.pdf", subtype: "FreeText", extra: "", nm: "ft-001", contents: "Free text callout", author: "Carol", color: "0 0 0", type: "free_text" },
  { kind: "ink", file: "ink.pdf", subtype: "Ink", extra: INK, nm: "ink-001", contents: "Freehand stroke", author: "Dana", color: "0 0 0", type: "ink" },
  { kind: "stamp", file: "stamp.pdf", subtype: "Stamp", extra: "", nm: "stp-001", contents: "Approved", author: "Dana", color: "1 0 0", type: "stamp" },
  { kind: "line", file: "line.pdf", subtype: "Line", extra: "/L [100 100 400 120]", nm: "ln-001", contents: "Straight line", author: "Dana", color: "0 0 0", type: "line" },
  { kind: "arrow", file: "arrow.pdf", subtype: "Line", extra: "/LE [/OpenArrow /OpenArrow] /L [100 100 400 120]", nm: "ar-001", contents: "Arrow", author: "Dana", color: "0 0 0", type: "line" },
  { kind: "double_arrow", file: "double_arrow.pdf", subtype: "Line", extra: "/LE [/OpenArrow /OpenArrow] /L [100 100 400 120]", nm: "da-001", contents: "Double arrow", author: "Dana", color: "0 0 0", type: "line" },
  { kind: "dimension", file: "dimension.pdf", subtype: "Line", extra: "/LE [/None /OpenArrow] /L [100 100 400 120]", nm: "dim-001", contents: "123 mm", author: "Dana", color: "0 0 0", type: "line" },
  { kind: "oval", file: "oval.pdf", subtype: "Circle", extra: "", nm: "ov-001", contents: "Oval", author: "Erin", color: "0.3 0.3 1", type: "circle" },
  { kind: "rectangle", file: "rectangle.pdf", subtype: "Square", extra: "", nm: "rc-001", contents: "Rectangle", author: "Erin", color: "0 0 0", type: "square" },
  { kind: "polygon", file: "polygon.pdf", subtype: "Polygon", extra: "/Vertices [100 100 200 100 150 180]", nm: "pg-001", contents: "Triangle", author: "Erin", color: "0 0 0", type: "polygon" },
  { kind: "cloud", file: "cloud.pdf", subtype: "Polygon", extra: "/Vertices [100 100 200 100 200 180 100 180]", nm: "cl-001", contents: "Cloud", author: "Erin", color: "0 0.5 0", type: "polygon" },
  { kind: "polyline", file: "polyline.pdf", subtype: "Polyline", extra: "/Vertices [100 100 200 120 300 100]", nm: "pl-001", contents: "Polyline", author: "Erin", color: "0 0 0", type: "polyline" },
  { kind: "file_attachment", file: "file_attachment.pdf", subtype: "FileAttachment", extra: "", nm: "fa-001", contents: "attached note", author: "Fay", color: "1 0 0", type: "file_attachment" },
  { kind: "whiteout", file: "whiteout.pdf", subtype: "Square", extra: "", nm: "wo-001", contents: "Whiteout", author: "Fay", color: "1 1 1", type: "square" },
];
if (fixtures.length < 19) { console.error("fixture count too low:", fixtures.length); process.exit(1); }

mkdirSync(OUT_DIR, { recursive: true });
const manifest = fixtures.map((f) => ({
  kind: f.kind, file: f.file, subtype: f.subtype,
  expected_type: f.type, expected_nm: f.nm,
  expected_contents: f.contents, author: f.author,
  expected_bounds: { left: 100, bottom: 100, right: 400, top: 120 },
  note: "Round-trip fixture for kind " + f.kind,
}));

for (const f of fixtures) {
  writeFileSync(join(OUT_DIR, f.file), singlePagePdf({ annots: [ann(f.subtype, f.nm, f.contents, f.author, f.color, f.extra || "")] }));
}

const variant = () => [
  ann("Highlight", "v-hl", "Variant highlight", "Ada", "1 1 0", QUAD),
  ann("Ink", "v-ink", "Variant ink", "Ada", "0 0 0", INK),
  ann("Square", "v-rect", "Variant rectangle", "Ada", "0 0.5 0", ""),
];
writeFileSync(join(OUT_DIR, "rotated_annotated.pdf"), singlePagePdf({ rotate: 90, annots: variant() }));
writeFileSync(join(OUT_DIR, "cropped_origin_annotated.pdf"), singlePagePdf({ cropBox: [72, 72, 540, 720], annots: variant() }));

writeFileSync(join(OUT_DIR, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log("Wrote " + fixtures.length + " fixtures + 2 variants to " + OUT_DIR);
console.log(manifest.map((m) => m.kind + " -> " + m.file).join("\n"));
