// mutate.js — T-088
// Thin facade over @cantoo/pdf-lib. No hook or LiveView code imports
// @cantoo/pdf-lib directly — this is the only module that does.
// Maintains the current document in memory for the active workspace.

import { PDFDocument as PdfLibDocument, StandardFonts } from "@cantoo/pdf-lib";

let currentPdfBytes = null;
let currentDoc = null;

/**
 * Load a PDF document from bytes.
 * @param {Uint8Array} bytes
 * @returns {Promise<import("@cantoo/pdf-lib").PDFDocument>}
 */
async function load(bytes) {
  currentPdfBytes = bytes;
  currentDoc = await PdfLibDocument.load(bytes);
  return currentDoc;
}

/**
 * Returns the current PDFDocument instance, or null if none loaded.
 */
function getDocument() {
  return currentDoc;
}

/**
 * Save the current document back to bytes (Uint8Array).
 * Updates the internal byte cache.
 * @returns {Promise<Uint8Array|null>}
 */
async function save() {
  if (!currentDoc) return null;
  const pdfBytes = await currentDoc.save({ useObjectStreams: true });
  currentPdfBytes = pdfBytes;
  return pdfBytes;
}

/**
 * Get the current raw PDF bytes (from last load or save).
 * @returns {Uint8Array|null}
 */
function getBytes() {
  return currentPdfBytes;
}

/**
 * Apply a mutation function to the current document, then save.
 * Returns the new bytes.
 * @param {(doc: import("@cantoo/pdf-lib").PDFDocument) => Promise<void>|void} mutatorFn
 * @returns {Promise<Uint8Array>}
 */
async function applyMutation(mutatorFn) {
  if (!currentDoc) throw new Error("No document loaded");
  await mutatorFn(currentDoc);
  return await save();
}

/**
 * Check whether a document is currently loaded.
 * @returns {boolean}
 */
function isLoaded() {
  return currentDoc !== null;
}

// ── Clipboard → new single-page PDF (T-079) ──────────────────────────────
// These build a fresh document (not the workspace document) from clipboard
// payloads: text becomes a wrapped text page, PNG/JPEG becomes a fitted
// image page. Letter size, 72 pt margins.

const LETTER_W = 612;
const LETTER_H = 792;
const MARGIN = 72;

/** Wrap `text` to the printable width for the given font/size. */
function wrapText(text, font, size, maxWidth) {
  const words = text.split(/\s+/).filter(Boolean);
  const lines = [];
  let line = "";
  for (const word of words) {
    const candidate = line ? `${line} ${word}` : word;
    if (font.widthOfTextAtSize(candidate, size) <= maxWidth || !line) {
      line = candidate;
    } else {
      lines.push(line);
      line = word;
    }
  }
  if (line) lines.push(line);
  return lines;
}

/**
 * Build a single-page PDF from clipboard text.
 * @param {string} text
 * @returns {Promise<Uint8Array>}
 */
async function createFromText(text) {
  const doc = await PdfLibDocument.create();
  const page = doc.addPage([LETTER_W, LETTER_H]);
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const size = 12;
  const lineHeight = size * 1.4;
  const maxWidth = LETTER_W - 2 * MARGIN;
  const lines = wrapText(text, font, size, maxWidth);

  let y = LETTER_H - MARGIN;
  for (const line of lines) {
    if (y < MARGIN) break;
    page.drawText(line, { x: MARGIN, y, size, font });
    y -= lineHeight;
  }
  return doc.save();
}

/**
 * Build a single-page PDF from a clipboard image blob (PNG or JPEG).
 * The image is centered and scaled to fit within the margins, aspect
 * preserved, never upscaled.
 * @param {Blob} blob
 * @returns {Promise<Uint8Array>}
 */
async function createFromImage(blob) {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const doc = await PdfLibDocument.create();
  const page = doc.addPage([LETTER_W, LETTER_H]);
  const img =
    blob.type === "image/png"
      ? await doc.embedPng(bytes)
      : await doc.embedJpg(bytes);
  const maxW = LETTER_W - 2 * MARGIN;
  const maxH = LETTER_H - 2 * MARGIN;
  const scale = Math.min(maxW / img.width, maxH / img.height, 1);
  const w = img.width * scale;
  const h = img.height * scale;
  page.drawImage(img, { x: (LETTER_W - w) / 2, y: (LETTER_H - h) / 2, width: w, height: h });
  return doc.save();
}

/**
 * Clear the current document state (e.g. on close).
 */
function reset() {
  currentPdfBytes = null;
  currentDoc = null;
}

export { load, save, getBytes, getDocument, applyMutation, isLoaded, createFromText, createFromImage, reset };
