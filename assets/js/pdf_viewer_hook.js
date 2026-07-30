// PdfViewerHook — plan3.md §3.2, T-042
//
// Colocated LiveView hook wrapping pdf.js's PDFViewer, EventBus and
// PDFLinkService. Mounted on the #document-canvas element.
//
// Import viewer components, not the full viewer app (§3.2 lines 259-262).
// pdf.js is loaded dynamically from the vendor copy via pdf_viewer.js.

import { init, openDocument, createViewer, pdfjsLib } from "./pdf_viewer.js";
import { TextFormatBar } from "./text_format_bar.js";

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
    this._scriptingEnabled = false;
    this._scriptingManager = null;

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

    // Toggle annotation editor mode (FreeText, etc.)
    this.handleEvent("toggle_editing", ({ mode }) => {
      if (!this._viewer) return;
      const { AnnotationEditorType } = pdfjsLib;

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
    });

    // Track editor selection changes to show/hide the format bar
    this._eventBus.on("editingstateschanged", ({ details }) => {
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

    const opts = { scriptingEnabled: this._scriptingEnabled };
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

  /**
   * Clean up and null out the current viewer and its dependencies
   * (called before re-creating with different options).
   */
  _destroyViewer() {
    if (this._formatBarAutoHideHandler) {
      document.removeEventListener("pointerdown", this._formatBarAutoHideHandler, true);
      this._formatBarAutoHideHandler = null;
    }
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
  }

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
  }

  /** Hide the format bar. */
  _hideFormatBar() {
    if (this._formatBar) {
      this._formatBar.hide();
    }
    this._activeEditor = null;
  }

  /** Sync the format bar controls from the active editor's current state. */
  _syncFormatBarFromEditor() {
    if (!this._formatBar || !this._uiManager) return;
    const editor = this._uiManager.getActive();
    if (!editor) return;
    this._activeEditor = editor;
    const styles = this._collectEditorStyles(editor);
    this._formatBar.updateStyles(styles);
  }

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
  }

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
  }

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
  }

  /**
   * Apply a CSS style to the active editor's contenteditable div.
   */
  _applyEditorStyle(prop, value) {
    if (!this._activeEditor || !this._activeEditor.editorDiv) return;
    this._activeEditor.editorDiv.style[prop] = value;
  }

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
  }

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
  }

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
  }

  /**
   * Prompt for a value and apply as a CSS property.
   */
  _promptAndApply(prop, msg, fallback) {
    const val = prompt(msg, fallback);
    if (val !== null) {
      this._applyEditorStyle(prop, val);
    }
  }

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
  }

  /** Convert an rgb/rgba string to hex. */
  _rgbToHex(rgb) {
    const m = rgb.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
    if (!m) return "#ffff00";
    const r = parseInt(m[1], 10).toString(16).padStart(2, "0");
    const g = parseInt(m[2], 10).toString(16).padStart(2, "0");
    const b = parseInt(m[3], 10).toString(16).padStart(2, "0");
    return `#${r}${g}${b}`;
  }

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
