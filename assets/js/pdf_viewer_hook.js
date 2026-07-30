// PdfViewerHook — plan3.md §3.2, T-042
//
// Colocated LiveView hook wrapping pdf.js's PDFViewer, EventBus and
// PDFLinkService. Mounted on the #document-canvas element.
//
// Import viewer components, not the full viewer app (§3.2 lines 259-262).
// pdf.js is loaded dynamically from the vendor copy via pdf_viewer.js.

import { init, openDocument, createViewer } from "./pdf_viewer.js";

const PdfViewerHook = {
  mounted() {
    this._viewer = null;
    this._eventBus = null;
    this._linkService = null;
    this._findController = null;
    this._pdfDocument = null;

    // Initialise pdf.js (idempotent)
    init().then(() => {
      const container = this.el.querySelector("#pdf-viewer-container");
      if (!container) return;
      const { viewer, eventBus, linkService, findController } =
        createViewer(container);

      this._viewer = viewer;
      this._eventBus = eventBus;
      this._linkService = linkService;
      this._findController = findController;

      this._wireEvents();

      // If server pre-set a document URL, open it
      const docUrl = this.el.dataset.documentUrl;
      if (docUrl && container) {
        this._openDocument(docUrl);
      }
    });

    // LiveView push_event handlers
    this.handleEvent("open_document", ({ url, password }) => {
      this._openDocument(url, password);
    });

    this.handleEvent("navigate_page", ({ page }) => {
      if (this._viewer) this._viewer.currentPageNumber = page;
    });

    this.handleEvent("set_zoom", ({ zoom }) => {
      if (this._viewer) this._viewer.currentScale = zoom / 100;
    });

    this.handleEvent("set_scroll_mode", ({ mode }) => {
      if (this._viewer) this._viewer.scrollMode = mode;
    });

    this.handleEvent("set_spread_mode", ({ mode }) => {
      if (this._viewer) this._viewer.spreadMode = mode;
    });

    this.handleEvent("close_document", () => {
      this._closeDocument();
    });
  },

  destroyed() {
    this._closeDocument();
  },

  _wireEvents() {
    if (!this._viewer || !this._eventBus) return;

    this._eventBus.on("pagechanging", ({ pageNumber }) => {
      this.pushEvent("page_changed", { page: pageNumber });
    });

    this._eventBus.on("documentloaded", () => {
      const doc = this._viewer.pdfDocument;
      if (doc) {
        this.pushEvent("document_loaded", {
          page_count: doc.numPages,
        });
      }
    });

    this._eventBus.on("pagesinit", () => {
      this.pushEvent("document_ready", {
        current_page: this._viewer.currentPageNumber,
        total_pages: this._viewer.pagesCount,
      });
    });

    this._eventBus.on("scalechanging", ({ scale }) => {
      this.pushEvent("zoom_changed", { zoom: Math.round(scale * 100) });
    });
  },

  _openDocument(url, password) {
    if (!this._viewer) return;
    this._closeDocument();

    const opts = {};
    if (password) opts.password = password;

    openDocument(url, opts)
      .then((pdfDocument) => {
        this._pdfDocument = pdfDocument;
        this._viewer.setDocument(pdfDocument);
        if (this._findController) this._findController.setDocument(pdfDocument);
      })
      .catch((err) => {
        this.pushEvent("document_error", {
          message: err.message || "Unknown error",
          name: err.name || "UnknownError",
        });
      });
  },

  _closeDocument() {
    if (this._viewer) this._viewer.setDocument(null);
    if (this._findController) this._findController.setDocument(null);
    this._pdfDocument = null;
  },
};

export default PdfViewerHook;
