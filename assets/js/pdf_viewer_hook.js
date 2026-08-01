// PdfViewerHook — plan3.md §3.2, T-042
//
// Colocated LiveView hook wrapping pdf.js's PDFViewer, EventBus and
// PDFLinkService. Mounted on the #document-canvas element.
//
// Import viewer components, not the full viewer app (§3.2 lines 259-262).
// pdf.js is loaded dynamically from the vendor copy via pdf_viewer.js.

import { init, openDocument, createViewer, pdfjsLib } from "./pdf_viewer.js";
import { TextFormatBar } from "./text_format_bar.js";
import OpfsCache from "./opfs_cache_hook.js";

const PdfViewerHook = {
  mounted() {
    this._viewer = null;
    this._eventBus = null;
    this._linkService = null;
    this._findController = null;
    this._pdfDocument = null;
    this._previousEditorMode = 0;
    this._editModeEnabled = false;
    this._uiManager = null;
    this._activeEditor = null;
    this._formatBar = null;
    this._formatBarAutoHideHandler = null;
    this._formatPainterActive = false;
    this._formatPainterStyle = null;
    this._formatPainterClickHandler = null;
    this._selectTextActive = false;
    // Fill & Sign palette state (T-117): the client draw layer for the five
    // lightweight self-signing tools. `_fillSign` holds the active tool and
    // its option settings; placed items are tracked so Esc/Done can clear
    // the layer.
    this._fillSignTool = null;
    this._fillSignOptions = {
      font: "Helvetica",
      font_size: "12",
      text_color: "#1f2937",
      glyph_color: "#1f2937",
      line_weight: "2",
      line_color: "#1f2937"
    };
    this._fillSignItems = [];
    // Expose mode-switch helpers to sibling hooks (AnnotEditHook) so the
    // select-text mode stays exclusive with object-selection tools.
    this.el._deactivateSelectText = () => this._deactivateSelectText();
    this.el._deactivateFormatPainter = () => this._deactivateFormatPainter();
    this._scriptingEnabled = false;
    this._scriptingManager = null;
    this._docKey = null; // sha256(documentUrl) — OPFS render-cache key prefix (§14.2)
    OpfsCache._init();

    // Initialise pdf.js (idempotent)
    init().then(() => {
      const container = this.el.querySelector("#pdf-viewer-container");
      if (!container) return;

      this._createViewerInstance(container);

      // If server pre-set a document URL, open it
      const docUrl = this.el.dataset.documentUrl;
      if (docUrl) {
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

    // Toggle scripting sandbox (pdf-fkm)
    this.handleEvent("set_scripting", ({ enabled }) => {
      const was = this._scriptingEnabled;
      this._scriptingEnabled = !!enabled;
      if (was !== this._scriptingEnabled && this._pdfDocument) {
        // Document is open — close and reopen so scripting manager is
        // created or destroyed and page views re-bind JS actions.
        this._closeDocument();
        const docUrl = this.el.dataset.documentUrl;
        if (docUrl) {
          // Re-create the viewer with the new scripting setting
          const container = this.el.querySelector("#pdf-viewer-container");
          if (container) {
            this._destroyViewer();
            this._createViewerInstance(container);
            this._openDocument(docUrl);
          }
        }
      }
    });

    // Enter/esgin field placement mode (T-147)
    this.handleEvent("enable_esign_placement", () => {
      this._enableEsignPlacement();
    });

    this.handleEvent("disable_esign_placement", () => {
      this._disableEsignPlacement();
    });

    // Signature placement mode (T-115): the server dispatched a saved
    // signature; clicking the page drops a movable/resizable box.
    this.handleEvent("enable_signature_placement", ({ signature, kind }) => {
      this._enableSignaturePlacement({ signature, kind: kind || "signature" });
    });

    // Text-stamp placement (T-116): signer's name and signing date are
    // drawn as text directly by the client — no saved slot involved.
    this.handleEvent("enable_name_stamp_placement", ({ text }) => {
      this._enableSignaturePlacement({ text, kind: "name" });
    });

    this.handleEvent("enable_date_stamp_placement", ({ text }) => {
      this._enableSignaturePlacement({ text, kind: "date" });
    });

    this.handleEvent("signature_placement_failed", () => {
      this._disableSignaturePlacement();
    });

    // Form-field detection preview (T-125): server drew detected boxes
    // over the scanned form; accept/discard clears them.
    this.handleEvent("form_detection_preview", ({ fields }) => {
      this._showFormDetectionOverlay(fields);
    });

    this.handleEvent("form_detection_clear", () => {
      this._clearFormDetectionOverlay();
    });

    // Fill & Sign palette (T-117): the server pushed the active tool and its
    // option settings. The client owns the draw layer — FreeText editor for
    // text, vector SVG overlays for the crossmark/checkmark/dot/line. Uses
    // the detected form-field boxes (`_formDetectFields`) for snapping.
    this.handleEvent("toggle_fill_sign_tool", ({ tool, active, ...styles }) => {
      this._syncFillSignOptions(styles);
      if (!active || !tool) {
        this._disableFillSignTool();
        return;
      }
      this._enableFillSignTool(tool);
    });

    // Palette option controls changed (font / size / colour / weight).
    this.handleEvent("fill_sign_options", (opts) => {
      this._syncFillSignOptions(opts);
      if (this._fillSignTool === "text") this._applyFillTextOptions();
    });

    // Fill & Sign auto-fill (T-116): the user asked to fill every detected
    // field. The server sends per-page field rects (PDF user-space points);
    // place an empty text box anchored at the centre of each one.
    this.handleEvent("fill_automatically", ({ fields }) => {
      this._clearFillSignLayer();
      this._fillSignItems = [];
      if (!fields || !fields.length) return;
      const o = this._fillSignOptions;
      const pts = Math.max(8, parseFloat(o.font_size) || 12);
      for (const f of fields) {
        const pv = this._viewer?._pages?.[f.page_index];
        if (!pv || !f.rect || f.rect.length !== 4) continue;
        const r = f.rect;
        this._fillSignItems.push({
          id: "af-" + this._fillId(),
          kind: "text",
          pageIndex: f.page_index,
          pt: [(r[0] + r[2]) / 2, (r[1] + r[3]) / 2],
          font: o.font,
          size: pts,
          color: o.text_color,
          text: ""
        });
      }
      for (const item of this._fillSignItems) this._renderFillText(item);
    });

    // Toggle annotation editor mode (FreeText, etc.)
    this.handleEvent("toggle_editing", ({ mode }) => {
      if (!this._viewer) return;
      const { AnnotationEditorType } = pdfjsLib;

      // Edit tools are exclusive: starting Add/Edit text turns off the
      // format painter and select-text modes.
      this._deactivateSelectTextMode();
      this._deactivateFormatPainter();

      if (mode === "add_text") {
        const currentMode = this._viewer.annotationEditorMode;
        if (currentMode === AnnotationEditorType.FREETEXT) {
          // Toggle off: capture committed editors first, then deactivate
          this._captureCommittedEditors();
          this._viewer.annotationEditorMode = { mode: AnnotationEditorType.NONE };
        } else {
          // Toggle on: activate FreeText mode
          this._viewer.annotationEditorMode = { mode: AnnotationEditorType.FREETEXT };
        }
      } else if (mode === "edit_text") {
        // Edit mode — client-side click-on-text is handled by the
        // server-driven workflow: the server identifies the run via
        // Quire.Editor.RunIdentifier and opens a FreeText editor for
        // the selected text region, then receives edits via
        // text.edit ops.
        if (this._editModeEnabled) {
          // Toggle off: restore normal viewer interaction
          this._editModeEnabled = false;
          this._viewer.annotationEditorMode = { mode: AnnotationEditorType.NONE };
          this._unbindEditTextClick();
          this.pushEvent("edit_mode_changed", { active: false });
        } else {
          // Toggle on: switch to edit mode, disable FreeText creation
          this._editModeEnabled = true;
          this._viewer.annotationEditorMode = { mode: AnnotationEditorType.NONE };
          this._bindEditTextClick();
          this.pushEvent("edit_mode_changed", { active: true });
        }
      }
    });

    // Format painter (T-094): copy the style of the currently selected
    // text/annotation object, then apply it to the next object clicked.
    // Reacts to the server ribbon button (`toggle_format_painter`).
    this.handleEvent("toggle_format_painter", ({ active }) => {
      if (!active) {
        this._deactivateFormatPainter();
        return;
      }

      // Capture the style of the currently selected editor.
      if (!this._uiManager) {
        this.pushEvent("format_painter_state", { active: false, reason: "no_ui_manager" });
        return;
      }
      const editor = this._uiManager.getActive();
      if (!editor || !editor.editorDiv) {
        this.pushEvent("format_painter_state", { active: false, reason: "nothing_selected" });
        return;
      }

      this._formatPainterStyle = this._collectEditorStyles(editor);
      this._formatPainterActive = true;
      this._activateFormatPainterCursor();
      this._bindFormatPainterClick();
    });

    // Select text mode (T-094): switch the pointer to select the page's
    // existing (rendered) text rather than moving/editing objects. This is
    // exclusive with the annotation-editor object-selection modes.
    this.handleEvent("toggle_select_text", ({ active }) => {
      if (!active) {
        this._deactivateSelectText();
        return;
      }
      // Exclusive: leaving any editor/text-add mode.
      this._deactivateFormatPainter();
      if (this._editModeEnabled) {
        this._editModeEnabled = false;
        this._unbindEditTextClick();
      }
      this._activateSelectText();
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

    // Flush pending client edits (pdf-7ov): save modified PDF bytes
    // and push the result back so the server can create an intermediate
    // revision before applying a server-side op.
    this.handleEvent("request_save", async () => {
      if (!this._pdfDocument) {
        this.pushEvent("save_error", { reason: "no_document" });
        return;
      }
      try {
        const data = await this._pdfDocument.saveDocument();
        const bytes = new Uint8Array(data);
        // Convert to base64 for the LiveView wire
        let binary = "";
        for (let i = 0; i < bytes.length; i++) {
          binary += String.fromCharCode(bytes[i]);
        }
        const base64 = btoa(binary);
        this.pushEvent("document_saved", { bytes: base64, byte_size: bytes.length });
      } catch (err) {
        this.pushEvent("save_error", { reason: err.message || "save_failed" });
      }
    });

    // Handle server response to open a FreeText editor for the clicked run
    this.handleEvent("open_text_editor", ({ text, bbox, font_name, font_size, page_index }) => {
      this._openTextEditorAtRun(text, bbox, font_name, font_size, page_index);
    });

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
    this._disableSignaturePlacement();
    this._deactivateFormatPainter();
    this._deactivateSelectText();
    if (this._formatBarAutoHideHandler) {
      document.removeEventListener("pointerdown", this._formatBarAutoHideHandler, true);
      this._formatBarAutoHideHandler = null;
    }
    this._hideFormatBar();
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
      // Re-render any form-detection preview overlays (page views are
      // recreated on scale change).
      if (this._formDetectFields) this._showFormDetectionOverlay(this._formDetectFields);
    });

    // OPFS render cache (§14.2): on pagerender (before the draw) restore
    // a cached bitmap for an instant paint; pdf.js then re-renders over it
    // asynchronously (same-scale hits are pixel-identical, so the extra
    // render is invisible). On pagerendered, store the finished canvas.
    this._eventBus.on("pagerender", ({ pageNumber }) => {
      this._restorePageFromOpfs(pageNumber);
    });

    this._eventBus.on("pagerendered", (evt) => {
      if (!evt || evt.cssTransform || evt.isDetailView) return;
      this._cachePageToOpfs(evt);
    });

    // FindState: 0=FOUND, 1=NOT_FOUND — the search has settled, so
    // report the flattened match list to the search panel.
    this._eventBus.on("updatefindcontrolstate", ({ state }) => {
      if (state === 0 || state === 1) this._pushSearchResults();
    });

    // Track annotation editor mode changes and capture committed editors
    this._eventBus.on("annotationeditormodechanged", ({ mode }) => {
      const { AnnotationEditorType } = pdfjsLib;
      if (this._previousEditorMode === AnnotationEditorType.FREETEXT && mode === AnnotationEditorType.NONE) {
        this._captureCommittedEditors();
        this._hideFormatBar();
      }
      this._previousEditorMode = mode;
    });

    // Capture the AnnotationEditorUIManager reference for format bar
    this._eventBus.on("annotationeditoruimanager", ({ uiManager }) => {
      this._uiManager = uiManager;
      // Expose for the Playwright tests and sibling hooks.
      this.el._uiManager = uiManager;
    });

    // Track editor selection changes to show/hide the format bar
    this._eventBus.on("editingstateschanged", ({ details }) => {
      // Report selection so the server can enable/disable the Format
      // painter ribbon button (T-094 done-when #1) — it is only usable
      // once a text/annotation object is selected.
      this.pushEvent("edit_selection_changed", { selected: !!details.hasSelectedEditor });

      if (!this._formatBar) return;
      if (details.hasSelectedEditor) {
        this._showFormatBar();
      } else {
        // Only hide if we're not in FreeText mode (editor may be temporarily blurred)
        const { AnnotationEditorType } = pdfjsLib;
        if (this._previousEditorMode !== AnnotationEditorType.FREETEXT) {
          this._hideFormatBar();
        }
      }
    });

    // React to internal property changes (size, colour via picker, etc.)
    this._eventBus.on("annotationeditorparamschanged", ({ details }) => {
      if (!this._formatBar || !this._formatBar._visible) return;
      this._syncFormatBarFromEditor();
    });
  },

  // ── OPFS page-render cache (§14.2) ─────────────────────────────────────

  // Key = sha256(docUrl):page:scale — the plan's "sha256 + page + scale".
  // LRU-bounded (60 entries) through OpfsCache.putLRU.
  async _hashDocUrl(url) {
    try {
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(url));
      this._docKey = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
    } catch {
      this._docKey = "doc:" + url.replace(/[^a-zA-Z0-9]/g, "");
    }
  },

  _opfsKey(pageNumber, scale) {
    if (!this._docKey) return null;
    const s = Math.round(scale * 100) / 100;
    return `${this._docKey}:${pageNumber}:${s}`;
  },

  _cachePageToOpfs(evt) {
    if (!this._viewer || !this._pdfDocument || !evt || !evt.source) return;
    const key = this._opfsKey(evt.pageNumber, evt.scale || this._viewer.currentScale);
    if (!key) return;
    const canvas = evt.source?.canvas;
    if (!canvas || !canvas.width || !canvas.height) return;
    try {
      canvas.toBlob((blob) => {
        if (blob && blob.size > 0) OpfsCache.putLRU(key, blob, 60);
      }, "image/png");
    } catch {
      // Caching is best-effort — never break rendering.
    }
  },

  _restorePageFromOpfs(pageNumber) {
    if (!this._docKey) return;
    const scale = this._viewer ? this._viewer.currentScale : 1;
    const key = this._opfsKey(pageNumber, scale);
    if (!key) return;
    OpfsCache.getLRU(key)
      .then((blob) => {
        if (!blob || !this._viewer) return;
        const pageView = this._viewer.getPageView(pageNumber - 1);
        if (!pageView || !pageView.canvas) return;
        // Guard against scale changes racing the async read.
        if (Math.round(this._viewer.currentScale * 100) / 100 !== Math.round(scale * 100) / 100) return;
        return createImageBitmap(blob).then((bmp) => {
          if (pageView.canvas.width === 0) return;
          pageView.canvas.getContext("2d").drawImage(bmp, 0, 0);
          bmp.close();
        });
      })
      .catch(() => {});
  },

  _pushSearchResults() {
    const fc = this._findController;
    if (!fc) return;

    // pdf.js 6.x computes matches incrementally: updatefindcontrolstate
    // (FOUND) fires as soon as the FIRST matching page is ready, while
    // remaining pages are still being matched. Wait for every page's text
    // extraction promise to settle before reading _pageMatches, so the
    // server receives the COMPLETE hit set (Gate 2 verify #5).
    const extractPromises = fc._extractTextPromises || [];
    const query = fc.state ? fc.state.query : "";
    const matchCase = fc.state ? fc.state.caseSensitive : false;
    const wholeWord = fc.state ? fc.state.entireWord : false;

    Promise.all(extractPromises)
      .then(() => {
        // A newer search may have started while we waited — drop stale results.
        const state = fc.state;
        if (!state || state.query !== query) return;
        if (state.caseSensitive !== matchCase || state.entireWord !== wholeWord) return;

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
      })
      .catch(() => {});
  },

  _openDocument(url, password) {
    if (!this._viewer) return;
    this._closeDocument();

    // OPFS render-cache key prefix — sha256 of the document URL (stable per
    // document). Compute async; cache hits simply miss until it resolves.
    this._docKey = null;
    this._hashDocUrl(url);

    const opts = { scriptingEnabled: this._scriptingEnabled };
    if (password) opts.password = password;

    openDocument(url, opts)
      .then((pdfDocument) => {
        this._pdfDocument = pdfDocument;
        // Wire the link service BEFORE the viewer: PDFFindController reads
        // linkService.pagesCount/page, which need pdfDocument on the link
        // service (and the viewer on it for page navigation). pdf.js's own
        // viewer app does this in PDFViewerApplication; our hook must too
        // (Gate 2 verify #5 — the client search path).
        if (this._linkService) {
          this._linkService.setViewer(this._viewer);
          this._linkService.setDocument(pdfDocument);
        }
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

  /**
   * Clean up and null out the current viewer and its dependencies
   * (called before re-creating with different options).
   */
  _destroyViewer() {
    if (this._formatBarAutoHideHandler) {
      document.removeEventListener("pointerdown", this._formatBarAutoHideHandler, true);
      this._formatBarAutoHideHandler = null;
    }
    this._deactivateFormatPainter();
    this._deactivateSelectText();
    this._hideFormatBar();
    this._viewer = null;
    this._eventBus = null;
    this._linkService = null;
    this._findController = null;
    this._scriptingManager = null;
    this._formatBar = null;
    this._uiManager = null;
    this._activeEditor = null;
  },

  /**
   * Create a fresh viewer instance inside an already-cleaned container.
   * Called by set_scripting toggle to re-create the viewer with a
   * different scripting mode.
   */
  _createViewerInstance(container) {
    const { viewer, eventBus, linkService, findController, scriptingManager } =
      createViewer(container, { scriptingEnabled: this._scriptingEnabled });

    this._viewer = viewer;
    this._eventBus = eventBus;
    this._linkService = linkService;
    this._findController = findController;
    this._scriptingManager = scriptingManager;

    this._wireEvents();

    // Re-expose on the element for sibling hooks
    this.el._pdfViewer = this._viewer;
    this.el._eventBus = this._eventBus;
    this.el._findController = this._findController;

    // Re-init the format bar
    this._initFormatBar();
  },

  // --- Floating format bar (T-090) ---

  /** Create the TextFormatBar instance attached to the viewer wrapper. */
  _initFormatBar() {
    const wrapper = this.el.querySelector("#pdf-viewer-wrapper");
    if (!wrapper) return;

    this._formatBar = new TextFormatBar({
      container: wrapper,
      eventBus: this._eventBus,
      onStyleChange: (type, value) => this._onFormatBarChange(type, value),
    });

    // Auto-hide format bar when clicking outside both it and the editor
    this._formatBarAutoHideHandler = (e) => {
      if (!this._formatBar || !this._formatBar._visible) return;
      const barEl = this._formatBar._el;
      if (!barEl) return;

      // If click is inside the format bar — ignore
      if (barEl.contains(e.target)) return;

      // If click is inside the active editor(s) — ignore
      if (this._activeEditor) {
        if (this._activeEditor.div && this._activeEditor.div.contains(e.target)) return;
        if (this._activeEditor.editorDiv && this._activeEditor.editorDiv.contains(e.target)) return;
      }

      // Click was outside — hide
      this._hideFormatBar();
    };
    document.addEventListener("pointerdown", this._formatBarAutoHideHandler, true);
  },

  /** Show the format bar positioned above the active editor. */
  _showFormatBar() {
    if (!this._formatBar || !this._uiManager) return;

    const editor = this._uiManager.getActive();
    if (!editor || !editor.div) return;

    this._activeEditor = editor;

    // Get the editor's bounding rect relative to the viewport
    const rect = editor.div.getBoundingClientRect();
    const styles = this._collectEditorStyles(editor);

    this._formatBar.show(rect, styles);
  },

  /** Hide the format bar. */
  _hideFormatBar() {
    if (this._formatBar) {
      this._formatBar.hide();
    }
    this._activeEditor = null;
  },

  /** Sync the format bar controls from the active editor's current state. */
  _syncFormatBarFromEditor() {
    if (!this._formatBar || !this._uiManager) return;
    const editor = this._uiManager.getActive();
    if (!editor) return;
    this._activeEditor = editor;
    const styles = this._collectEditorStyles(editor);
    this._formatBar.updateStyles(styles);
  },

  /**
   * Read all style properties from a FreeText editor into a plain object.
   * @param {object} editor - FreeTextEditor instance
   * @returns {object}
   */
  _collectEditorStyles(editor) {
    const div = editor.editorDiv;
    const style = div ? window.getComputedStyle(div) : {};

    // Parse font size from "calc(Xpx * ...)"
    let fontSize = 12;
    if (editor.editorDiv) {
      const cs = style.fontSize || "";
      const m = cs.match(/(\d+(\.\d+)?)/);
      if (m) fontSize = parseFloat(m[1]);
    }

    return {
      fontFamily:     style.fontFamily ? style.fontFamily.split(",")[0].replace(/['"]/g, "").trim() : "Helvetica",
      fontSize,
      bold:           style.fontWeight === "bold" || parseInt(style.fontWeight, 10) >= 700,
      italic:         style.fontStyle === "italic",
      underline:      style.textDecorationLine ? style.textDecorationLine.includes("underline") : false,
      strikethrough:  style.textDecorationLine ? style.textDecorationLine.includes("line-through") : false,
      fontColor:      editor.color || style.color || "#000000",
      highlightColor: style.backgroundColor && style.backgroundColor !== "rgba(0, 0, 0, 0)" && style.backgroundColor !== "transparent"
        ? this._rgbToHex(style.backgroundColor)
        : "#ffff00",
      alignment:      style.textAlign || "left",
    };
  },

  /**
   * Handle a style change from the format bar.
   * @param {string} type - Style property key
   * @param {*} value - New value
   */
  _onFormatBarChange(type, value) {
    switch (type) {
      case "fontSize":
        this._dispatchEditorParam(11, value); // FREETEXT_SIZE
        break;

      case "fontColor":
        this._dispatchEditorParam(12, value); // FREETEXT_COLOR
        break;

      case "fontFamily":
        this._applyEditorStyle("fontFamily", value);
        break;

      case "bold":
        // value is the toggled active state — invert
        this._applyEditorStyle("fontWeight", value ? "bold" : "normal");
        break;

      case "italic":
        this._applyEditorStyle("fontStyle", value ? "italic" : "normal");
        break;

      case "underline":
        this._toggleTextDecoration("underline", value);
        break;

      case "strikethrough":
        this._toggleTextDecoration("line-through", value);
        break;

      case "highlightColor":
        this._applyEditorStyle("backgroundColor", value);
        break;

      case "alignment":
        this._applyEditorStyle("textAlign", value);
        break;

      case "indent":
        this._adjustIndent(value);
        break;

      case "link":
        this._insertLink();
        break;

      case "lineSpacing":
        this._promptAndApply("lineHeight", "Enter line spacing (e.g. 1.5):", "1.5");
        break;

      case "charSpacing":
        this._promptAndApply("letterSpacing", "Enter character spacing in px (e.g. 1):", "0");
        break;

      case "superscript":
        this._applyEditorStyle("verticalAlign", "super");
        this._applyEditorStyle("fontSize", "smaller");
        break;

      case "subscript":
        this._applyEditorStyle("verticalAlign", "sub");
        this._applyEditorStyle("fontSize", "smaller");
        break;

      case "case":
        this._cycleTextCase();
        break;

      case "close":
        this._hideFormatBar();
        break;
    }
  },

  /**
   * Dispatch a pdf.js annotation editor param update via eventBus.
   * @param {number} type - AnnotationEditorParamsType constant
   * @param {*} value
   */
  _dispatchEditorParam(type, value) {
    if (!this._eventBus) return;
    this._eventBus.dispatch("switchannotationeditorparams", {
      source: this,
      type,
      value,
    });
  },

  /**
   * Apply a CSS style to the active editor's contenteditable div.
   */
  _applyEditorStyle(prop, value) {
    if (!this._activeEditor || !this._activeEditor.editorDiv) return;
    this._activeEditor.editorDiv.style[prop] = value;
  },

  /**
   * Toggle a text-decoration line value on/off.
   */
  _toggleTextDecoration(line, active) {
    if (!this._activeEditor || !this._activeEditor.editorDiv) return;
    const div = this._activeEditor.editorDiv;
    const cur = div.style.textDecorationLine || "";
    const lines = cur.split(/\s+/).filter(Boolean);
    if (active) {
      if (!lines.includes(line)) lines.push(line);
    } else {
      const idx = lines.indexOf(line);
      if (idx !== -1) lines.splice(idx, 1);
    }
    div.style.textDecorationLine = lines.join(" ");
  },

  /**
   * Adjust the left padding of the editor to simulate indent/outdent.
   * @param {number} dir - +1 to increase, -1 to decrease
   */
  _adjustIndent(dir) {
    if (!this._activeEditor || !this._activeEditor.editorDiv) return;
    const div = this._activeEditor.editorDiv;
    const cur = parseFloat(div.style.paddingLeft) || 0;
    const step = 20;
    div.style.paddingLeft = `${Math.max(0, cur + dir * step)}px`;
  },

  /**
   * Insert an anchor/link into the editor content.
   */
  _insertLink() {
    if (!this._activeEditor || !this._activeEditor.editorDiv) return;
    const url = prompt("Enter URL:");
    if (!url) return;
    const div = this._activeEditor.editorDiv;
    const selection = window.getSelection();
    if (selection && selection.rangeCount && div.contains(selection.anchorNode)) {
      document.execCommand("createLink", false, url);
    } else {
      // No selection — insert a placeholder link
      const link = document.createElement("a");
      link.href = url;
      link.textContent = url;
      link.target = "_blank";
      div.appendChild(link);
    }
  },

  /**
   * Prompt for a value and apply as a CSS property.
   */
  _promptAndApply(prop, msg, fallback) {
    const val = prompt(msg, fallback);
    if (val !== null) {
      this._applyEditorStyle(prop, val);
    }
  },

  /**
   * Cycle text-transform through none → uppercase → capitalize → none.
   */
  _cycleTextCase() {
    if (!this._activeEditor || !this._activeEditor.editorDiv) return;
    const div = this._activeEditor.editorDiv;
    const cur = div.style.textTransform || "";
    const order = ["", "uppercase", "capitalize"];
    const idx = order.indexOf(cur);
    div.style.textTransform = order[(idx + 1) % order.length];
  },

  /** Convert an rgb/rgba string to hex. */
  _rgbToHex(rgb) {
    const m = rgb.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
    if (!m) return "#ffff00";
    const r = parseInt(m[1], 10).toString(16).padStart(2, "0");
    const g = parseInt(m[2], 10).toString(16).padStart(2, "0");
    const b = parseInt(m[3], 10).toString(16).padStart(2, "0");
    return `#${r}${g}${b}`;
  },

  // ── Format painter (T-094) ────────────────────────────────────────

  /**
   * Set the armed crosshair cursor while the format painter is on.
   */
  _activateFormatPainterCursor() {
    const container = this.el.querySelector("#pdf-viewer-container") || this.el;
    container.classList.add("format-painter-armed");
  },

  /**
   * Bind a click handler that applies the captured format to the next
   * text/annotation object the user clicks.
   */
  _bindFormatPainterClick() {
    this._unbindFormatPainterClick();
    const container = this.el.querySelector("#pdf-viewer-container") || this.el;
    const handler = (e) => {
      if (!this._formatPainterActive || !this._formatPainterStyle) return;
      const editor = this._findEditorAtTarget(e.target);
      if (editor && editor.editorDiv) {
        e.preventDefault();
        this._applyCapturedStyle(editor, this._formatPainterStyle);
        this._deactivateFormatPainter();
        this.pushEvent("format_painter_applied", { applied: true });
      }
    };
    this._formatPainterClickHandler = handler;
    container.addEventListener("click", handler);
  },

  _unbindFormatPainterClick() {
    if (!this._formatPainterClickHandler) return;
    const container = this.el.querySelector("#pdf-viewer-container") || this.el;
    container.removeEventListener("click", this._formatPainterClickHandler);
    this._formatPainterClickHandler = null;
  },

  /**
   * Deactivate the format painter: unbind the click handler, clear the
   * captured style and armed cursor.
   */
  _deactivateFormatPainter() {
    this._unbindFormatPainterClick();
    this._formatPainterActive = false;
    this._formatPainterStyle = null;
    const container = this.el.querySelector("#pdf-viewer-container") || this.el;
    container.classList.remove("format-painter-armed");
  },

  /**
   * Locate the pdf.js editor (annotation-layer object) under a DOM target
   * by walking up to an editor wrapper and matching it against every live
   * editor in the uiManager.
   *
   * @returns {object|null} the matched FreeText / annotation editor
   */
  _findEditorAtTarget(target) {
    if (!target || !this._uiManager) return null;
    const wrapper = target.closest(".freeTextEditor, .annotationEditor");
    if (!wrapper) return null;

    const pages = this._viewer ? this._viewer._pages : [];
    for (let i = 0; i < pages.length; i++) {
      const editors = this._uiManager.getEditors(i);
      for (const editor of editors) {
        if (editor && editor.div === wrapper) return editor;
      }
    }
    return null;
  },

  /**
   * Apply a captured style object (from `_collectEditorStyles`) to the
   * contenteditable div of the target editor.
   */
  _applyCapturedStyle(editor, styles) {
    if (!editor || !editor.editorDiv) return;
    const div = editor.editorDiv;
    if (styles.fontFamily) div.style.fontFamily = styles.fontFamily;
    if (styles.fontSize) div.style.fontSize = `${styles.fontSize}px`;
    if (typeof styles.bold === "boolean") {
      div.style.fontWeight = styles.bold ? "bold" : "normal";
    }
    if (styles.italic) div.style.fontStyle = "italic";
    if (styles.fontColor) {
      div.style.color = styles.fontColor;
      if (editor.setColor) editor.setColor(styles.fontColor);
    }
    if (styles.highlightColor) div.style.backgroundColor = styles.highlightColor;
    if (styles.alignment) div.style.textAlign = styles.alignment;
    if (styles.underline) {
      const lines = div.style.textDecorationLine || "";
      if (!lines.includes("underline")) div.style.textDecorationLine = `${lines} underline`.trim();
    }
    if (styles.strikethrough) {
      const lines = div.style.textDecorationLine || "";
      if (!lines.includes("line-through")) div.style.textDecorationLine = `${lines} line-through`.trim();
    }
  },

  // ── Select text mode (T-094) ───────────────────────────────────────

  /**
   * Activate select-text mode: switch the pointer so dragging selects the
   * page's existing rendered text instead of selecting/moving objects.
   * Exits any annotation-editor mode and turns off the format painter so
   * the mode is exclusive with object selection.
   */
  _activateSelectText() {
    this._selectTextActive = true;

    const { AnnotationEditorType } = pdfjsLib;
    if (this._viewer) {
      try {
        this._viewer.annotationEditorMode = { mode: AnnotationEditorType.NONE };
      } catch (_) { /* ignore */ }
    }

    const container = this.el.querySelector("#pdf-viewer-container") || this.el;
    container.classList.add("select-text-mode");
  },

  _deactivateSelectText() {
    if (!this._selectTextActive) return;
    this._selectTextActive = false;
    const container = this.el.querySelector("#pdf-viewer-container") || this.el;
    container.classList.remove("select-text-mode");
  },

  _deactivateSelectTextMode() {
    this._deactivateSelectText();
  },

  // Serialize committed editors (FreeText etc.) from annotationStorage
  // and push the data to the server as a free_text_committed event.
  _captureCommittedEditors() {
    if (!this._pdfDocument) return;
    try {
      const storage = this._pdfDocument.annotationStorage;
      const data = storage.serializable;
      if (!data || !data.map || data.map.size === 0) return;

      const editors = [];
      for (const [id, editorData] of data.map) {
        // AnnotationEditorType.FREETEXT === 3
        if (editorData.annotationType === 3) {
          editors.push({ id, ...editorData });
        }
      }

      if (editors.length > 0) {
        this.pushEvent("free_text_committed", { editors });
      }
    } catch (e) {
      // Editors will be captured on save via saveDocument()
    }
  },

// ── Fill & Sign palette draw layer (T-117) ────────────────────────────
  //
  // Lightweight self-signing tools, distinct from E-Sign. Text is a
  // contenteditable box that auto-sizes to its content with font/size/
  // colour; crossmark / checkmark / filled dot are vector SVG glyphs placed
  // into resizable, movable boxes that snap to nearby detected form-field-
  // sizes; line is a straight vector line with adjustable weight/colour and
  // Shift-constrain to horizontal/vertical.
  //
  // Items are drawn into layers inside the page div (the same coordinate
  // space pdf.js uses for annotation layers).

  // Merge pushed option overrides into the palette option set.
  _syncFillSignOptions(opts) {
    if (!opts) return;
    const o = this._fillSignOptions;
    if (opts.font) o.font = opts.font;
    if (opts.font_size) o.font_size = String(opts.font_size);
    if (opts.text_color) o.text_color = opts.text_color;
    if (opts.glyph_color) o.glyph_color = opts.glyph_color;
    if (opts.line_weight) o.line_weight = String(opts.line_weight);
    if (opts.line_color) o.line_color = opts.line_color;
  },

  // Activate a Fill & Sign tool (exclusive with other editing modes).
  _enableFillSignTool(tool) {
    if (this._editModeEnabled) {
      this._editModeEnabled = false;
      this._unbindEditTextClick();
    }
    this._deactivateSelectTextMode();
    this._deactivateFormatPainter();
    if (this._viewer) {
      try {
        this._viewer.annotationEditorMode = { mode: pdfjsLib.AnnotationEditorType.NONE };
      } catch (_) {}
    }
    this._fillSignTool = tool;
    this._bindFillSignPlace();
    const c = this.el.querySelector("#pdf-viewer-container");
    if (c) c.classList.add("fill-sign-tool-active");
  },

  // Deactivate the active tool and clear the draw layer.
  _disableFillSignTool() {
    this._unbindFillSignPlace();
    this._finishFillDrag();
    this._clearFillSignLayer();
    this._fillSignItems = [];
    this._fillSignTool = null;
    const c = this.el.querySelector("#pdf-viewer-container");
    if (c) c.classList.remove("fill-sign-tool-active");
  },

  _bindFillSignPlace() {
    this._unbindFillSignPlace();
    const c = this.el.querySelector("#pdf-viewer-container");
    if (!c) return;
    this._fillSignClickHandler = (e) => this._onFillSignPlace(e);
    c.addEventListener("click", this._fillSignClickHandler);
  },

  _unbindFillSignPlace() {
    if (this._fillSignClickHandler) {
      const c = this.el.querySelector("#pdf-viewer-container");
      if (c) c.removeEventListener("click", this._fillSignClickHandler);
      this._fillSignClickHandler = null;
    }
  },

  // Find the page under the cursor and the matching PDF-space point.
  _fillHit(clientX, clientY) {
    if (!this._viewer || !this._viewer._pages) return null;
    for (const pv of this._viewer._pages) {
      if (!pv || !pv.div) continue;
      const pr = pv.div.getBoundingClientRect();
      if (clientX >= pr.left && clientX <= pr.right && clientY >= pr.top && clientY <= pr.bottom) {
        const [pdfX, pdfY] = pv.viewport.convertToPdfPoint(
          clientX - pr.left,
          clientY - pr.top
        );
        return { pv, pdfX, pdfY };
      }
    }
    return null;
  },

  _onFillSignPlace(e) {
    const tool = this._fillSignTool;
    if (!tool) return;
    const hit = this._fillHit(e.clientX, e.clientY);
    if (!hit) return;
    if (tool === "line") this._fillStartLine(hit, e);
    else if (tool === "text") this._fillPlaceText(hit);
    else this._fillPlaceGlyph(tool, hit);
  },

  _fillId() {
    return "fs-" + Math.random().toString(36).slice(2, 10);
  },

  // ---- glyphs (crossmark / checkmark / filled dot) ----------------------

  // Snap a newly-placed glyph box to a nearby detected form-field box.
  _snapGlyphRect(pv, pdfX, pdfY, size) {
    const fields = this._formDetectFields || [];
    const pageFields = fields.filter((f) => f.page_index === pv.id - 1);
    let best = null;
    let bestD = Infinity;
    for (const f of pageFields) {
      const r = f.rect;
      const cxp = (r[0] + r[2]) / 2;
      const cyp = (r[1] + r[3]) / 2;
      const d = Math.hypot(cxp - pdfX, cyp - pdfY);
      if (d < 120 && d < bestD) {
        best = r;
        bestD = d;
      }
    }
    if (best) return best.slice();
    return [pdfX - size / 2, pdfY - size / 2, pdfX + size / 2, pdfY + size / 2];
  },

  _fillPlaceGlyph(kind, hit) {
    const rect = this._snapGlyphRect(hit.pv, hit.pdfX, hit.pdfY, 26);
    const item = {
      id: this._fillId(),
      kind,
      pageIndex: hit.pv.id - 1,
      rect,
      color: this._fillSignOptions.glyph_color
    };
    this._fillSignItems.push(item);
    this._fillRenderGlyph(item);
  },

  _fillGlyphLabel(kind) {
    if (kind === "crossmark") return "Crossmark";
    if (kind === "checkmark") return "Checkmark";
    return "Filled dot";
  },

  // A positioned, draggable + resizable wrapper box around a glyph.
  _fillBox(item, pv) {
    const id = "fbox-" + item.id;
    let box = pv.div.querySelector(`#${id}`);
    if (box) return box;
    box = document.createElement("div");
    box.id = id;
    box.className = "fill-sign-box";
    box.dataset.fillKind = item.kind;
    box.setAttribute(
      "aria-label",
      `${this._fillGlyphLabel(item.kind)} — drag to move, corner to resize`
    );
    const handle = document.createElement("div");
    handle.className = "fill-sign-handle";
    handle.setAttribute("aria-hidden", "true");
    box.appendChild(handle);
    pv.div.appendChild(box);

    box.addEventListener("pointerdown", (ev) => {
      const resizing = ev.target.classList.contains("fill-sign-handle");
      this._fillBoxDrag(pv, item, ev, resizing);
    });
    this._positionFillBox(pv, item, box);
    return box;
  },

  _positionFillBox(pv, item, box) {
    const [x0, y0, x1, y1] = item.rect;
    const [p0x, p0y] = pv.viewport.convertToViewportPoint(x0, y0);
    const [p1x, p1y] = pv.viewport.convertToViewportPoint(x1, y1);
    box.style.left = `${Math.min(p0x, p1x)}px`;
    box.style.top = `${Math.min(p0y, p1y)}px`;
    box.style.width = `${Math.abs(p1x - p0x)}px`;
    box.style.height = `${Math.abs(p1y - p0y)}px`;
  },

  _fillRenderGlyph(item) {
    const pv = this._viewer?._pages?.[item.pageIndex];
    if (!pv) return;
    const box = this._fillBox(item, pv);
    let svg = box.querySelector("svg.fill-sign-glyph");
    if (!svg) {
      svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      svg.setAttribute("class", "fill-sign-glyph");
      svg.setAttribute("preserveAspectRatio", "none");
      box.appendChild(svg);
    }
    const vw = Math.max(item.rect[2] - item.rect[0], 1);
    const vh = Math.max(item.rect[3] - item.rect[1], 1);
    const stroke = Math.max(1, Math.min(vw, vh) * 0.09);
    let body = "";
    if (item.kind === "crossmark") {
      body =
        `<line x1="2" y1="2" x2="${vw - 2}" y2="${vh - 2}" stroke="${item.color}" stroke-width="${stroke}" stroke-linecap="round"/>` +
        `<line x1="${vw - 2}" y1="2" x2="2" y2="${vh - 2}" stroke="${item.color}" stroke-width="${stroke}" stroke-linecap="round"/>`;
    } else if (item.kind === "checkmark") {
      body =
        `<polyline points="${(vw * 0.15).toFixed(1)},${(vh * 0.5).toFixed(1)} ${(vw * 0.42).toFixed(1)},${(vh * 0.78).toFixed(1)} ${(vw * 0.85).toFixed(1)},${(vh * 0.22).toFixed(1)}"` +
        ` fill="none" stroke="${item.color}" stroke-width="${stroke}" stroke-linecap="round" stroke-linejoin="round"/>`;
    } else {
      body =
        `<circle cx="${(vw / 2).toFixed(1)}" cy="${(vh / 2).toFixed(1)}" r="${(Math.min(vw, vh) * 0.3).toFixed(1)}" fill="${item.color}"/>`;
    }
    svg.setAttribute("viewBox", `0 0 ${vw} ${vh}`);
    svg.innerHTML = body;
    this._positionFillBox(pv, item, box);
  },

  // Generic box drag: moving the body, or resizing from the corner handle.
  _fillBoxDrag(pv, item, startEvent, resizing) {
    this._finishFillDrag();
    const vp = pv.viewport;
    const pr = pv.div.getBoundingClientRect();
    const toPdf = (ev) => vp.convertToPdfPoint(ev.clientX - pr.left, ev.clientY - pr.top);
    const [sx, sy] = toPdf(startEvent);
    const [ox0, oy0, ox1, oy1] = item.rect;
    this._fillDrag = {
      onMove: (ev) => {
        const [px, py] = toPdf(ev);
        const dx = px - sx;
        const dy = py - sy;
        let x0 = ox0, y0 = oy0, x1 = ox1, y1 = oy1;
        if (resizing) {
          x1 = ox0 + Math.max(dx, 6);
          y1 = oy0 + Math.max(dy, 6);
        } else {
          x0 = ox0 + dx; x1 = ox1 + dx;
          y0 = oy0 + dy; y1 = oy1 + dy;
        }
        item.rect = [x0, y0, x1, y1];
        this._fillRenderGlyph(item);
      },
      onUp: () => this._finishFillDrag()
    };
    document.addEventListener("pointermove", this._fillDrag.onMove);
    document.addEventListener("pointerup", this._fillDrag.onUp);
  },

  _finishFillDrag() {
    if (this._fillDrag) {
      document.removeEventListener("pointermove", this._fillDrag.onMove);
      document.removeEventListener("pointerup", this._fillDrag.onUp);
    }
    this._fillDrag = null;
  },

  // ---- line tool -------------------------------------------------------

  _fillStartLine(hit, startEvent) {
    this._finishFillDrag();
    const o = this._fillSignOptions;
    const pv = hit.pv;
    const vp = pv.viewport;
    const pr = pv.div.getBoundingClientRect();
    const toPdf = (ev) => vp.convertToPdfPoint(ev.clientX - pr.left, ev.clientY - pr.top);
    const [ax, ay] = toPdf(startEvent);
    const weight = Number(o.line_weight || 2);
    let other = [ax, ay];

    const draw = (bx, by) => {
      this._fillLineSvg(pv).replaceChildren();
      this._drawVectorLine(this._fillLineSvg(pv), pv, ax, ay, bx, by, o.line_color, weight);
    };
    draw(ax, ay);

    this._fillDrag = {
      onMove: (ev) => {
        let [px, py] = toPdf(ev);
        // Shift-constrain horizontal / vertical from the start endpoint.
        if (ev.shiftKey) {
          if (Math.abs(px - ax) > Math.abs(py - ay)) py = ay;
          else px = ax;
        }
        other = [px, py];
        draw(px, py);
      },
      onUp: () => {
        this._finishFillDrag();
        const item = {
          id: "line-" + this._fillId(),
          kind: "line",
          pageIndex: pv.id - 1,
          start: [ax, ay],
          end: other,
          color: o.line_color,
          weight
        };
        this._fillSignItems.push(item);
      }
    };
    document.addEventListener("pointermove", this._fillDrag.onMove);
    document.addEventListener("pointerup", this._fillDrag.onUp);
  },

  _fillRenderLine(item) {
    const pv = this._viewer?._pages?.[item.pageIndex];
    if (!pv) return;
    this._drawVectorLine(this._fillLineSvg(pv), pv, item.start[0], item.start[1], item.end[0], item.end[1], item.color, item.weight);
  },

  // A dedicated full-page SVG layer per page collecting its lines.
  _fillLineSvg(pv) {
    let svg = pv.div.querySelector("svg.fill-sign-line-layer");
    if (svg) return svg;
    svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "fill-sign-line-layer");
    svg.setAttribute("aria-hidden", "true");
    pv.div.appendChild(svg);
    return svg;
  },

  _drawVectorLine(svg, pv, ax, ay, bx, by, color, weight) {
    const [vax, vay] = pv.viewport.convertToViewportPoint(ax, ay);
    const [vbx, vby] = pv.viewport.convertToViewportPoint(bx, by);
    const el = document.createElementNS("http://www.w3.org/2000/svg", "line");
    el.setAttribute("x1", vax);
    el.setAttribute("y1", vay);
    el.setAttribute("x2", vbx);
    el.setAttribute("y2", vby);
    el.setAttribute("stroke", color);
    el.setAttribute("stroke-width", String(weight));
    el.setAttribute("stroke-linecap", "round");
    svg.appendChild(el);
  },

  // ---- text tool -----------------------------------------------------

  _fillPlaceText(hit) {
    const o = this._fillSignOptions;
    const pts = Math.max(8, parseFloat(o.font_size) || 11);
    const item = {
      id: "text-" + this._fillId(),
      kind: "text",
      pageIndex: hit.pv.id - 1,
      pt: [hit.pdfX, hit.pdfY],
      font: o.font,
      size: pts,
      color: o.text_color,
      text: ""
    };
    this._fillSignItems.push(item);
    this._renderFillText(item);
    const layer = hit.pv.div.querySelector(`[data-fill-text="${item.id}"]`);
    const input = layer?.querySelector(".fill-sign-text");
    setTimeout(() => input?.focus(), 0);
  },

  _renderFillText(item) {
    const pv = this._viewer?._pages?.[item.pageIndex];
    if (!pv) return;
    let layer = pv.div.querySelector(`[data-fill-text="${item.id}"]`);
    if (!layer) {
      layer = document.createElement("div");
      layer.className = "fill-sign-text-wrap";
      layer.dataset.fillText = item.id;
      pv.div.appendChild(layer);
    }
    // Anchor layer to the click point in CSS px.
    const [vx, vy] = pv.viewport.convertToViewportPoint(item.pt[0], item.pt[1]);
    layer.style.left = `${vx}px`;
    layer.style.top = `${vy}px`;

    const input = document.createElement("div");
    input.className = "fill-sign-text";
    input.setAttribute("contenteditable", "true");
    input.style.fontFamily = item.font;
    input.style.fontSize = `${item.size}px`;
    input.style.color = item.color;
    input.textContent = item.text;
    input.setAttribute("minWidth", "120px");
    input.addEventListener("input", () => {
      item.text = input.innerText || "";
      // Auto-size: let the CSS width grow; keep the box as wide as content.
      layer.style.width = "auto";
    });
    input.addEventListener("blur", () => {
      if (!item.text) {
        // Remove empty boxes so stray clicks don't leave debris.
        this._fillSignItems = this._fillSignItems.filter((it) => it.id !== item.id);
        layer.remove();
      }
    });
    layer.replaceChildren(input);
  },

  // Apply palette option changes straight to live text boxes.
  _applyFillTextOptions() {
    const o = this._fillSignOptions;
    for (const item of this._fillSignItems) {
      if (item.kind !== "text") continue;
      item.font = o.font;
      item.size = Math.max(8, parseFloat(o.font_size) || item.size);
      item.color = o.text_color;
      this._renderFillText(item);
    }
  },

  // ---- render / clear helpers --------------------------------------------

  _renderFillItem(item) {
    if (item.kind === "line") this._fillRenderLine(item);
    else if (item.kind === "text") this._renderFillText(item);
    else this._fillRenderGlyph(item);
  },

  _clearFillSignLayer() {
    if (!this._viewer || !this._viewer._pages) return;
    for (const pv of this._viewer._pages) {
      if (!pv?.div) continue;
      pv.div.querySelectorAll(".fill-sign-box, .fill-sign-text-wrap, svg.fill-sign-line-layer")
        .forEach((el) => el.remove());
    }
  },

  // ── E-Sign field placement (T-147) ─────────────────────────────────

  _enableEsignPlacement() {
    this._esignPlacementEnabled = true;
    this._bindEsignPlaceClick();
  },

  _disableEsignPlacement() {
    this._esignPlacementEnabled = false;
    this._unbindEsignPlaceClick();
  },

  _bindEsignPlaceClick() {
    this._unbindEsignPlaceClick();
    const container = this.el.querySelector("#pdf-viewer-container");
    if (!container) return;
    this._esignPlaceClickHandler = (e) => this._onEsignPlaceClick(e);
    container.addEventListener("click", this._esignPlaceClickHandler);
  },

  _unbindEsignPlaceClick() {
    if (!this._esignPlaceClickHandler) return;
    const container = this.el.querySelector("#pdf-viewer-container");
    if (container) {
      container.removeEventListener("click", this._esignPlaceClickHandler);
    }
    this._esignPlaceClickHandler = null;
  },

  _onEsignPlaceClick(e) {
    if (!this._esignPlacementEnabled || !this._viewer) return;

    const container = this.el.querySelector("#pdf-viewer-container");
    const rect = container.getBoundingClientRect();
    const cssX = e.clientX - rect.left;
    const cssY = e.clientY - rect.top;

    const pages = this._viewer._pages;
    if (!pages) return;

    for (let i = 0; i < pages.length; i++) {
      const pv = pages[i];
      if (!pv || !pv.div) continue;
      const pr = pv.div.getBoundingClientRect();

      if (e.clientX >= pr.left && e.clientX <= pr.right &&
          e.clientY >= pr.top && e.clientY <= pr.bottom) {
        const vp = pv.viewport;
        const pageIndex = pv.id - 1;
        const [pdfX, pdfY] = vp.convertToPdfPoint(cssX, cssY);

        // Encode a default field size (120x24pt at the click point)
        const field = {
          page_index: pageIndex,
          rect: [pdfX, pdfY, pdfX + 120, pdfY + 24]
        };

        this.pushEvent("esign_wizard_place_field", field);
        this._disableEsignPlacement();
        break;
      }
    }
  },

  // ── Form-field detection preview (T-125) ───────────────────────────────

  /**
   * Draw dashed rectangles over detected form fields.
   *
   * Server sends rects in PDF user space (points, y-up, crop-origin
   * included); pdf.js viewports convert them straight to CSS pixels via
   * `convertToViewportPoint`, which already applies rotation + scale.
   */
  _showFormDetectionOverlay(fields) {
    this._clearFormDetectionOverlay();
    if (!this._viewer || !fields || !fields.length) return;

    this._formDetectFields = fields;
    const pages = this._viewer._pages;
    if (!pages) return;

    for (const pv of pages) {
      if (!pv || !pv.div || !pv.viewport) continue;
      const pageIndex = pv.id - 1;
      const pageFields = fields.filter((f) => f.page_index === pageIndex);
      if (!pageFields.length) continue;

      const vp = pv.viewport;
      for (const f of pageFields) {
        const [x0, y0] = vp.convertToViewportPoint(f.rect[0], f.rect[1]);
        const [x1, y1] = vp.convertToViewportPoint(f.rect[2], f.rect[3]);
        const el = document.createElement("div");
        el.className = "quire-form-detect-overlay";
        el.dataset.kind = f.kind || "text";
        el.style.left = `${Math.min(x0, x1)}px`;
        el.style.top = `${Math.min(y0, y1)}px`;
        el.style.width = `${Math.abs(x1 - x0)}px`;
        el.style.height = `${Math.abs(y1 - y0)}px`;
        pv.div.appendChild(el);
      }
    }
  },

  /** Remove all detected-form-field overlays (T-125). */
  _clearFormDetectionOverlay() {
    this._formDetectFields = null;
    if (!this._viewer) return;
    const pages = this._viewer._pages;
    if (!pages) return;
    for (const pv of pages) {
      if (!pv || !pv.div) continue;
      pv.div.querySelectorAll(".quire-form-detect-overlay").forEach((el) => el.remove());
    }
  },

  // ── Signature placement (T-115) ────────────────────────────────────────

  /** Enter placement mode: click a page to drop a resizable/movable box. */
  _enableSignaturePlacement({ signature = null, text = null, kind = "signature" } = {}) {
    this._sigPlacementSignature = signature;
    this._sigPlacementText = text;
    this._sigPlacementKind = kind;
    this._sigPlacementEnabled = true;
    this._bindSignaturePlaceClick();
    this._bindSignaturePlaceKeys();
    // Surface a hint so the user knows what to do next
    const hint = this.el.querySelector("#signature-placement-hint");
    if (hint) hint.classList.remove("hidden");
  },

  _disableSignaturePlacement() {
    this._sigPlacementEnabled = false;
    this._unbindSignaturePlaceClick();
    this._unbindSignaturePlaceKeys();
    this._removeSignatureOverlay();
    this._sigPlacementSignature = null;
    this._sigPlacementText = null;
    this._sigPlacementKind = null;
    const hint = this.el.querySelector("#signature-placement-hint");
    if (hint) hint.classList.add("hidden");
  },

  _bindSignaturePlaceClick() {
    this._unbindSignaturePlaceClick();
    const container = this.el.querySelector("#pdf-viewer-container");
    if (!container) return;
    this._sigPlaceClickHandler = (e) => this._onSignaturePlaceClick(e);
    container.addEventListener("click", this._sigPlaceClickHandler);
  },

  _unbindSignaturePlaceClick() {
    if (!this._sigPlaceClickHandler) return;
    const container = this.el.querySelector("#pdf-viewer-container");
    if (container) {
      container.removeEventListener("click", this._sigPlaceClickHandler);
    }
    this._sigPlaceClickHandler = null;
  },

  _bindSignaturePlaceKeys() {
    this._unbindSignaturePlaceKeys();
    this._sigPlaceKeyHandler = (e) => {
      if (e.key === "Escape") this._disableSignaturePlacement();
      if (e.key === "Enter") this._commitSignaturePlacement();
    };
    document.addEventListener("keydown", this._sigPlaceKeyHandler);
  },

  _unbindSignaturePlaceKeys() {
    if (!this._sigPlaceKeyHandler) return;
    document.removeEventListener("keydown", this._sigPlaceKeyHandler);
    this._sigPlaceKeyHandler = null;
  },

  /** Find the page under the cursor and drop a default-size box there. */
  _onSignaturePlaceClick(e) {
    if (!this._sigPlacementEnabled || !this._viewer) return;

    const pages = this._viewer._pages;
    if (!pages) return;

    for (let i = 0; i < pages.length; i++) {
      const pv = pages[i];
      if (!pv || !pv.div) continue;
      const pr = pv.div.getBoundingClientRect();

      if (
        e.clientX >= pr.left && e.clientX <= pr.right &&
        e.clientY >= pr.top && e.clientY <= pr.bottom
      ) {
        const vp = pv.viewport;
        const cssX = e.clientX - pr.left;
        const cssY = e.clientY - pr.top;
        const [pdfX, pdfY] = vp.convertToPdfPoint(cssX, cssY);

        // Default box: 40pt tall, width matching the signature's aspect
        const aspect = this._signatureAspectRatio();
        const h = 40;
        const w = h * aspect;

        this._createSignatureOverlay(pv, {
          page_index: pv.id - 1,
          rect: [pdfX, pdfY, pdfX + w, pdfY + h],
        });
        break;
      }
    }
  },

  /** Best-guess aspect ratio (width/height) for the default box size. */
  _signatureAspectRatio() {
    // Text stamps (signer name / date): width driven by text length
    if (this._sigPlacementKind === "name" || this._sigPlacementKind === "date") {
      const len = String(this._sigPlacementText || "").length;
      return Math.max(1.5, Math.min(10, len * 0.5));
    }
    const sig = this._sigPlacementSignature;
    if (!sig) return 3;
    let data = {};
    try {
      data = JSON.parse(sig.data);
    } catch {
      data = {};
    }
    if (sig.type === "draw") {
      const w = Number(data.width);
      const h = Number(data.height);
      if (w > 0 && h > 0) return Math.max(0.5, Math.min(8, w / h));
    }
    if (sig.type === "type") {
      const text = String(data.text || "").length;
      return Math.max(1, Math.min(6, text * 0.6));
    }
    return 3;
  },

  /** Create the draggable/resizable overlay box for the given page. */
  _createSignatureOverlay(pageView, state) {
    this._removeSignatureOverlay();
    this._sigOverlayState = state;
    this._sigOverlayPage = pageView;

    const overlay = document.createElement("div");
    overlay.className = "sig-placement-overlay";
    overlay.setAttribute("data-testid", "signature-placement-box");
    overlay.setAttribute("aria-label", "Signature placement — drag to move, corner handles to resize, Enter to place");

    // Corner resize handles
    for (const pos of ["nw", "ne", "sw", "se"]) {
      const handle = document.createElement("div");
      handle.className = `sig-placement-handle sig-placement-handle-${pos}`;
      handle.dataset.handle = pos;
      overlay.appendChild(handle);
    }

    // Commit / cancel controls
    const controls = document.createElement("div");
    controls.className = "sig-placement-controls";
    const placeBtn = document.createElement("button");
    placeBtn.type = "button";
    placeBtn.className = "sig-placement-btn";
    placeBtn.textContent = "Place";
    placeBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      this._commitSignaturePlacement();
    });
    const cancelBtn = document.createElement("button");
    cancelBtn.type = "button";
    cancelBtn.className = "sig-placement-btn sig-placement-btn-cancel";
    cancelBtn.textContent = "Cancel";
    cancelBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      this._disableSignaturePlacement();
    });
    controls.appendChild(placeBtn);
    controls.appendChild(cancelBtn);
    overlay.appendChild(controls);

    pageView.div.appendChild(overlay);
    this._sigOverlay = overlay;

    // Pointer interactions: body drag moves, handles resize
    overlay.addEventListener("pointerdown", (e) => {
      if (e.target.classList.contains("sig-placement-handle")) {
        this._beginSignatureDrag(e, e.target.dataset.handle);
      } else if (e.target.closest(".sig-placement-controls")) {
        // Buttons handle their own clicks
      } else {
        this._beginSignatureDrag(e, "move");
      }
    });

    this._renderSignatureOverlay();
  },

  _removeSignatureOverlay() {
    if (this._sigOverlay) {
      this._sigOverlay.remove();
      this._sigOverlay = null;
    }
    this._sigOverlayState = null;
    this._sigOverlayPage = null;
  },

  /** Position/size the overlay from the PDF-space rect (rotation-aware). */
  _renderSignatureOverlay() {
    const overlay = this._sigOverlay;
    const state = this._sigOverlayState;
    const pageView = this._sigOverlayPage;
    if (!overlay || !state || !pageView) return;

    const vp = pageView.viewport;
    const [x0, y0, x1, y1] = state.rect;
    const cx = (x0 + x1) / 2;
    const cy = (y0 + y1) / 2;
    const [vx, vy] = vp.convertToViewportPoint(cx, cy);
    const wCss = (x1 - x0) * vp.scale;
    const hCss = (y1 - y0) * vp.scale;

    overlay.style.left = `${vx - wCss / 2}px`;
    overlay.style.top = `${vy - hCss / 2}px`;
    overlay.style.width = `${wCss}px`;
    overlay.style.height = `${hCss}px`;
    overlay.style.transform = `rotate(${vp.rotation}deg)`;
    overlay.style.transformOrigin = "center";

    // Keep the commit/cancel controls upright on rotated pages
    const controls = overlay.querySelector(".sig-placement-controls");
    if (controls) {
      controls.style.transform = `translateX(-50%) rotate(${-vp.rotation}deg)`;
    }
  },

  _beginSignatureDrag(e, mode) {
    e.preventDefault();
    const pageView = this._sigOverlayPage;
    if (!pageView || !this._sigOverlayState) return;

    const pr = pageView.div.getBoundingClientRect();
    const vp = pageView.viewport;
    const [pdfX, pdfY] = vp.convertToPdfPoint(e.clientX - pr.left, e.clientY - pr.top);

    this._sigDrag = {
      mode,
      originPdf: [pdfX, pdfY],
      originRect: this._sigOverlayState.rect.slice(),
    };

    const onMove = (ev) => {
      const [curX, curY] = vp.convertToPdfPoint(ev.clientX - pr.left, ev.clientY - pr.top);
      const dx = curX - this._sigDrag.originPdf[0];
      const dy = curY - this._sigDrag.originPdf[1];
      this._applySignatureDrag(dx, dy);
    };
    const onUp = () => {
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerup", onUp);
      this._sigDrag = null;
    };

    document.addEventListener("pointermove", onMove);
    document.addEventListener("pointerup", onUp);
  },

  _applySignatureDrag(dx, dy) {
    const state = this._sigOverlayState;
    if (!state || !this._sigDrag) return;
    const [ox0, oy0, ox1, oy1] = this._sigDrag.originRect;
    let [x0, y0, x1, y1] = [ox0, oy0, ox1, oy1];

    switch (this._sigDrag.mode) {
      case "move":
        x0 = ox0 + dx; x1 = ox1 + dx;
        y0 = oy0 + dy; y1 = oy1 + dy;
        break;
      case "nw":
        x0 = Math.min(ox0 + dx, ox1 - 8); y0 = Math.min(oy0 + dy, oy1 - 8);
        break;
      case "ne":
        x1 = Math.max(ox1 + dx, ox0 + 8); y0 = Math.min(oy0 + dy, oy1 - 8);
        break;
      case "sw":
        x0 = Math.min(ox0 + dx, ox1 - 8); y1 = Math.max(oy1 + dy, oy0 + 8);
        break;
      case "se":
        x1 = Math.max(ox1 + dx, ox0 + 8); y1 = Math.max(oy1 + dy, oy0 + 8);
        break;
    }

    state.rect = [x0, y0, x1, y1];
    this._renderSignatureOverlay();
  },

  /** Rasterise the signature to PNG at the box size and commit. */
  async _commitSignaturePlacement() {
    const state = this._sigOverlayState;
    if (!state) return;

    const [x0, y0, x1, y1] = state.rect;
    const png = await this._rasterizeSignature(x1 - x0, y1 - y0);
    if (!png) {
      this.pushEvent("signature_placement_failed", { reason: "Could not rasterise signature" });
      return;
    }

    const kind = this._sigPlacementKind || "signature";
    this._disableSignaturePlacement();
    this.pushEvent("signature_placed", {
      page_index: state.page_index,
      rect: [x0, y0, x1, y1],
      png: png.split(",")[1] || png,
      kind,
    });
  },

  /** Draw the saved signature onto a fresh canvas at the target size. */
  async _rasterizeSignature(widthPdf, heightPdf) {
    // Text stamps (T-116): signer name / signing date drawn from text
    if (this._sigPlacementKind === "name" || this._sigPlacementKind === "date") {
      return this._rasterizeTextStamp(widthPdf, heightPdf, this._sigPlacementText || "");
    }

    const sig = this._sigPlacementSignature;
    if (!sig) return null;

    let data = {};
    try {
      data = JSON.parse(sig.data);
    } catch {
      data = {};
    }

    // Render at 2x for crisp print output
    const scale = 2;
    const w = Math.max(1, Math.round(widthPdf * scale));
    const h = Math.max(1, Math.round(heightPdf * scale));
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, w, h);

    if (sig.type === "draw") {
      this._drawSignatureStrokes(ctx, data, w, h);
    } else if (sig.type === "type") {
      this._drawSignatureText(ctx, data, w, h);
    } else if (sig.type === "upload") {
      const ok = await this._drawSignatureImage(ctx, data, w, h);
      if (!ok) return null;
    }

    return canvas.toDataURL("image/png");
  },

  /**
   * Rasterise a text stamp (signer name / signing date) onto a transparent
   * canvas at the target size. Text is centered and shrink-fitted so it
   * never overflows the box — same fit loop as `_drawSignatureText` but
   * with a plain sans-serif face (stamps are not script signatures).
   */
  _rasterizeTextStamp(widthPdf, heightPdf, text) {
    if (!text) return null;

    const scale = 2;
    const w = Math.max(1, Math.round(widthPdf * scale));
    const h = Math.max(1, Math.round(heightPdf * scale));
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, w, h);

    ctx.fillStyle = "#000";
    ctx.textBaseline = "middle";
    ctx.textAlign = "center";

    let size = Math.max(12, h * 0.5);
    const draw = (s) => {
      ctx.font = `${s}px Helvetica, Arial, sans-serif`;
      ctx.clearRect(0, 0, w, h);
      ctx.fillText(text, w / 2, h / 2);
      return ctx.measureText(text).width <= w * 0.96;
    };

    while (size > 6 && !draw(size)) {
      size *= 0.9;
    }
    draw(size);

    return canvas.toDataURL("image/png");
  },

  _drawSignatureStrokes(ctx, data, w, h) {
    const strokes = data.strokes || [];
    const srcW = Number(data.width) || w;
    const srcH = Number(data.height) || h;
    const sx = w / srcW;
    const sy = h / srcH;

    ctx.strokeStyle = "#000";
    ctx.lineWidth = 2.5 * sy;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";

    for (const stroke of strokes) {
      if (!stroke || stroke.length < 2) continue;
      ctx.beginPath();
      ctx.moveTo(stroke[0].x * sx, stroke[0].y * sy);
      for (let i = 1; i < stroke.length; i++) {
        ctx.lineTo(stroke[i].x * sx, stroke[i].y * sy);
      }
      ctx.stroke();
    }
  },

  _drawSignatureText(ctx, data, w, h) {
    const text = String(data.text || "");
    if (!text) return;
    const font = data.font || "Alex Brush";
    const srcSize = Number(data.size) || 48;

    // Fit the text within the box: start at the capture size, shrink if needed
    let size = srcSize * (h / 100);
    ctx.fillStyle = "#000";
    ctx.textBaseline = "middle";
    ctx.textAlign = "center";

    const draw = (s) => {
      ctx.font = `${s}px "${font}", cursive`;
      ctx.clearRect(0, 0, w, h);
      ctx.fillText(text, w / 2, h / 2);
      return ctx.measureText(text).width <= w * 0.98;
    };

    while (size > 8 && !draw(size)) {
      size *= 0.9;
    }
    draw(size);
  },

  _drawSignatureImage(ctx, data, w, h) {
    return new Promise((resolve) => {
      const img = new Image();
      img.onload = () => {
        const scale = Math.min(w / img.width, h / img.height);
        const dw = img.width * scale;
        const dh = img.height * scale;
        ctx.drawImage(img, (w - dw) / 2, (h - dh) / 2, dw, dh);
        resolve(true);
      };
      img.onerror = () => resolve(false);
      img.src = data.image || "";
    });
  },

  // ── Edit-mode click-to-select text (T-091, pdf-8vsn) ────────────────

  /** Bind click handler on the viewer container when edit mode is active. */
  _bindEditTextClick() {
    this._unbindEditTextClick();
    const container = this.el.querySelector("#pdf-viewer-container");
    if (!container) return;
    this._editTextClickHandler = (e) => this._onEditTextClick(e);
    container.addEventListener("click", this._editTextClickHandler);
  },

  /** Unbind the edit-mode click handler. */
  _unbindEditTextClick() {
    if (!this._editTextClickHandler) return;
    const container = this.el.querySelector("#pdf-viewer-container");
    if (container) {
      container.removeEventListener("click", this._editTextClickHandler);
    }
    this._editTextClickHandler = null;
  },

  /**
   * Handle a click on the text layer in edit mode.
   * Determines the page and PDF-space coordinates, then sends them
   * to the server for run identification.
   */
  _onEditTextClick(e) {
    if (!this._editModeEnabled || !this._viewer) return;

    // Find the page view that was clicked
    const container = this.el.querySelector("#pdf-viewer-container");
    const rect = container.getBoundingClientRect();
    const cssX = e.clientX - rect.left;
    const cssY = e.clientY - rect.top;

    // Iterate page views to find which page was clicked
    const pages = this._viewer._pages;
    if (!pages) return;

    for (let i = 0; i < pages.length; i++) {
      const pv = pages[i];
      if (!pv || !pv.div) continue;
      const pr = pv.div.getBoundingClientRect();

      if (e.clientX >= pr.left && e.clientX <= pr.right &&
          e.clientY >= pr.top && e.clientY <= pr.bottom) {
        // Found the clicked page — convert CSS coords to PDF points
        const vp = pv.viewport;
        const pageIndex = pv.id - 1; // pdf.js uses 1-based page id
        const [pdfX, pdfY] = vp.convertToPdfPoint(cssX, cssY);

        this.pushEvent("edit_text_click", {
          page_index: pageIndex,
          x: pdfX,
          y: pdfY
        });
        break;
      }
    }
  },

  /**
   * Open a pdf.js FreeText editor at the identified run's bounding box,
   * pre-populated with the run's text.
   */
  _openTextEditorAtRun(text, bbox, fontName, fontSize, pageIndex) {
    if (!this._viewer) return;
    const { AnnotationEditorType } = pdfjsLib;

    // Switch to FreeText annotation editor mode
    this._viewer.annotationEditorMode = { mode: AnnotationEditorType.FREETEXT };

    // Wait briefly for the editor layer to be ready, then create and position
    // the editor at the run's bounding box.
    setTimeout(() => {
      const editorLayer = this._viewer._annotationEditorLayer;
      if (!editorLayer) return;

      try {
        const [x0, y0, x1, y1] = bbox;
        const w = x1 - x0;
        const h = y1 - y0;
        const editor = editorLayer.createAndAddNewEditor(
          { x: x0, y: y0, width: w, height: h },
          /* isCentered */ false
        );

        if (editor && editor.editorDiv) {
          // Set the initial text content
          editor.editorDiv.textContent = text;
        }
      } catch (err) {
        console.warn("PdfViewerHook: openTextEditorAtRun failed:", err);
      }
    }, 50);
  },
};

export default PdfViewerHook;
