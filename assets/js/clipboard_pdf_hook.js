// Clipboard to PDF (T-079) — client half.
//
// ClipboardPdf: mounted on the ribbon "Clipboard to PDF" button. On click
// (user gesture) it reads the system clipboard via navigator.clipboard.read(),
// turns text or a PNG/JPEG image into a new single-page PDF with
// @cantoo/pdf-lib (see mutate.js), and pushes the bytes to the server for
// ingest as a new document. Permission/empty/unsupported failures push an
// error code so the server can surface the paste-target fallback.
//
// ClipboardPasteTarget: mounted on the fallback panel. Paste into the
// textarea (text or an image) or click "Convert" after typing; the same
// PDF-building pipeline runs.

import { createFromText, createFromImage } from "./mutate.js";

/** Encode bytes as base64 without blowing the call stack. */
function bytesToBase64(bytes) {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/** Shared: convert a clipboard payload and push it to the server. */
function pushPayload(hook, { text, blob }) {
  const build = text !== undefined ? createFromText(text) : createFromImage(blob);
  build
    .then((bytes) => {
      hook.pushEvent("clipboard_pdf_ready", {
        bytes: bytesToBase64(bytes),
        filename: "clipboard.pdf",
      });
    })
    .catch(() => {
      hook.pushEvent("clipboard_pdf_error", { code: "failed" });
    });
}

const ClipboardPdf = {
  mounted() {
    this.el.addEventListener("click", () => this._readClipboard());
  },

  async _readClipboard() {
    if (!navigator.clipboard || !navigator.clipboard.read) {
      this.pushEvent("clipboard_pdf_error", { code: "permission" });
      return;
    }
    try {
      const items = await navigator.clipboard.read();
      if (!items || items.length === 0) {
        this.pushEvent("clipboard_pdf_error", { code: "empty" });
        return;
      }
      const item = items.find(
        (i) =>
          i.types.includes("text/plain") ||
          i.types.some((t) => t === "image/png" || t === "image/jpeg"),
      );
      if (!item) {
        this.pushEvent("clipboard_pdf_error", { code: "unsupported" });
        return;
      }
      if (item.types.includes("text/plain")) {
        const blob = await item.getType("text/plain");
        const text = await blob.text();
        if (!text.trim()) {
          this.pushEvent("clipboard_pdf_error", { code: "empty" });
          return;
        }
        pushPayload(this, { text });
      } else {
        const type = item.types.find((t) => t === "image/png" || t === "image/jpeg");
        const blob = await item.getType(type);
        pushPayload(this, { blob });
      }
    } catch (err) {
      this.pushEvent("clipboard_pdf_error", {
        code: err && err.name === "NotAllowedError" ? "permission" : "failed",
      });
    }
  },
};

const ClipboardPasteTarget = {
  mounted() {
    this._onPaste = (e) => {
      const items = e.clipboardData ? Array.from(e.clipboardData.items) : [];
      const imageItem = items.find(
        (i) => i.type === "image/png" || i.type === "image/jpeg",
      );
      if (imageItem) {
        e.preventDefault();
        const blob = imageItem.getAsFile();
        if (blob) pushPayload(this, { blob });
        return;
      }
      const text = e.clipboardData ? e.clipboardData.getData("text/plain") : "";
      if (text && text.trim()) {
        pushPayload(this, { text });
      }
    };
    this._onConvert = () => {
      const textarea = this.el.querySelector("textarea");
      if (textarea && textarea.value.trim()) {
        pushPayload(this, { text: textarea.value });
      }
    };
    this.el.addEventListener("paste", this._onPaste);
    this.el.addEventListener("click", (e) => {
      if (e.target.closest("[data-clipboard-convert]")) this._onConvert();
    });
  },

  destroyed() {
    this.el.removeEventListener("paste", this._onPaste);
  },
};

export { ClipboardPdf, ClipboardPasteTarget };
