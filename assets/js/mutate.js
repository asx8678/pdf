// mutate.js — T-088
// Thin facade over @cantoo/pdf-lib. No hook or LiveView code imports
// @cantoo/pdf-lib directly — this is the only module that does.
// Maintains the current document in memory for the active workspace.

import { PDFDocument as PdfLibDocument } from "@cantoo/pdf-lib";

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

/**
 * Clear the current document state (e.g. on close).
 */
function reset() {
  currentPdfBytes = null;
  currentDoc = null;
}

export { load, save, getBytes, getDocument, applyMutation, isLoaded, reset };
