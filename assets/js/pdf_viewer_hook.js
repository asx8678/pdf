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
      // pdf.js ScrollMode: vertical=0, horizontal=1, wrapped=2
      const map = { vertical: 0, horizontal: 1, wrapped: 2 };
      const val = map[mode];
      if (val !== undefined && this._viewer) {
        this._viewer.scrollMode = val;
      }
    });

    this.handleEvent("set_spread_mode", ({ mode }) => {
      // pdf.js SpreadMode: none=0, odd=1, even=2 (single=0, facing=1, cover-facing=2)
      const map = { none: 0, single: 0, odd: 1, even: 2 };
      const val = map[mode];
      if (val !== undefined && this._viewer) {
        this._viewer.spreadMode = val;
      }
    });

    this.handleEvent("set_fit_mode", ({ mode }) => {
      if (!this._viewer) return;
      // pdf.js currentScaleValue: "page-fit", "page-width", "page-actual"
      const map = {
        fit_page: "page-fit",
        fit_width: "page-width",
        actual_size: "page-actual"
      };
      const val = map[mode];
      if (val) this._viewer.currentScaleValue = val;
    });

    this.handleEvent("close_document", () => {
      this._closeDocument();
    });

    // Ctrl+scroll zoom (T-051 §14.2: debounce re-render, CSS transform interim)
    this.el.addEventListener("wheel", (e) => {
      if (!e.ctrlKey && !e.metaKey) return;
      e.preventDefault();
      if (!this._viewer) return;

      const delta = e.deltaY > 0 ? -0.1 : 0.1;
      const newScale = Math.max(0.25, Math.min(5, this._viewer.currentScale + delta));
      this._viewer.currentScale = newScale;

      // Debounce the server push to 150ms (§14.2)
      clearTimeout(this._zoomTimer);
      this._zoomTimer = setTimeout(() => {
        this.pushEvent("zoom_changed", { zoom: Math.round(newScale * 100) });
        this._zoomTimer = null;
      }, 150);
    }, { passive: false });

    // Search panel (T-048) — run the find controller with the panel's
    // query and options; matches are highlighted in the text layer.
    this.handleEvent("find", ({ query, match_case, whole_word }) => {
      if (!this._eventBus) return;
      this._eventBus.dispatch("find", {
        type: "",
        query,
        phraseSearch: true,
        caseSensitive: !!match_case,
        entireWord: !!whole_word,
        highlightAll: true,
        findPrevious: false,
      });
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

    // FindState: 0=FOUND, 1=NOT_FOUND — the search has settled, so
    // report the flattened match list to the search panel.
    this._eventBus.on("updatefindcontrolstate", ({ state }) => {
      if (state === 0 || state === 1) this._pushSearchResults();
    });
  },

  // Flattens the find controller's per-page matches into
  // [%{page, text}] rows with a short context snippet for the panel.
  _pushSearchResults() {
    const fc = this._findController;
    if (!fc) return;

    const results = [];
    const pageMatches = fc._pageMatches || [];
    const pageContents = fc._pageContents || [];

    pageMatches.forEach((matches, pageIdx) => {
      const text = pageContents[pageIdx] || "";
      (matches || []).forEach((idx) => {
        const start = Math.max(0, idx - 40);
        const end = Math.min(text.length, idx + 60);
        results.push({
          page: pageIdx + 1,
          text: text.slice(start, end).replace(/\s+/g, " ").trim(),
        });
      });
    });

    this.pushEvent("search_results", { results, total: results.length });
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
