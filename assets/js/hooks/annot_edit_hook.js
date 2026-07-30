// AnnotEditHook — T-105 Phase 6 (shapes: T-106)
//
// LiveView hook for the pdf.js annotation editor layer. Switches
// annotation editor modes through PDFViewer.annotationEditorMode
// (never direct instantiation of AnnotationEditorLayer), listens to
// EventBus events for mode and state changes, and serialises committed
// annotations to the server via pushEvent.
//
// Shape annotations (T-106) use a custom SVG overlay instead of pdf.js
// built-in editors, since pdf.js does not have native shape tools.
// The hook intercepts shape modes, draws an SVG preview overlay, and
// serialises shape data to path_data on commit.
//
// Relies on PdfViewerHook (T-042) to initialise the PDFViewer and
// store references on `this.el._pdfViewer` / `this.el._eventBus`.

// AnnotationEditorType constant values — avoid importing pdf.mjs
// until the module is guaranteed loaded by PdfViewerHook.init().
const MODE_MAP = {
  stickyNote:   102,  // AnnotationEditorType.COMMENT
  highlight:     9,  // AnnotationEditorType.HIGHLIGHT
  underline:     9,  // HIGHLIGHT (underline is a text-markup subtype)
  strikethrough: 9,  // HIGHLIGHT (strikethrough is a text-markup subtype)
  squiggly:      9,  // HIGHLIGHT (squiggly is a text-markup subtype)
  freeText:      3,  // AnnotationEditorType.FREETEXT
  ink:          15,  // AnnotationEditorType.INK
};

// Shape modes — these are NOT pdf.js native editor modes; they activate
// custom SVG drawing via the hook. Stored in a set for quick lookup.
const SHAPE_MODES = new Set([
  "line",
  "arrow",
  "double_arrow",
  "dimension",
  "oval",
  "rectangle",
  "polygon",
  "cloud",
  "polyline",
  "whiteout",
]);

// Stamp modes — custom SVG stamp placement (built-in SVG + custom image/text)
const STAMP_MODES = new Set([
  "stamp",
]);

// File attachment mode — custom SVG pin icon placement
const FILE_ATTACHMENT_MODES = new Set([
  "file_attachment",
]);

// Free-text callout mode — custom free text with leader line
const FREE_TEXT_CALLOUT_MODES = new Set([
  "free_text_callout",
]);

// Measure modes (T-108) — distance, perimeter, area. These reuse the
// shape drawing infrastructure but render measurement labels and commit
// computed values. Measurements are computed in PDF points per §14.3 then
// scaled via calibration factor (stored in _calFactor / _calUnit).
const MEASURE_MODES = new Set([
  "measure_distance",
  "measure_perimeter",
  "measure_area",
]);

// All custom (non-native) modes combined for dispatch
const CUSTOM_MODES = new Set([
  ...SHAPE_MODES,
  ...STAMP_MODES,
  ...FILE_ATTACHMENT_MODES,
  ...FREE_TEXT_CALLOUT_MODES,
  ...MEASURE_MODES,
]);

// AnnotationEditorType constants used for comparison
const TYPE_NONE = 0;

// AnnotationEditorParamsType values for ink editor config
const PARAMS = {
  INK_COLOR: 21,
  INK_THICKNESS: 22,
  INK_OPACITY: 23,
  INK_COLOR_AND_OPACITY: 24,
};

// Sticky note icon set — matches the icon selector in the Comment tab ribbon.
const STICKY_ICONS = {
  note: "hero-chat-bubble-left-right",
  comment: "hero-chat-bubble-oval-left",
  key: "hero-key",
  help: "hero-question-mark-circle",
  paragraph: "hero-document-text",
};

// Built-in stamp definitions (SVG rendered in the browser).
// Each stamp has an id, label, and SVG content.
const BUILTIN_STAMPS = [
  {
    id: "approved",
    label: "Approved",
    svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 40">
      <rect width="120" height="40" rx="4" fill="#16a34a" fill-opacity="0.12" stroke="#16a34a" stroke-width="1.5"/>
      <text x="60" y="26" text-anchor="middle" font-family="Arial, sans-serif" font-size="14" font-weight="bold" fill="#16a34a">APPROVED</text>
    </svg>`,
  },
  {
    id: "draft",
    label: "Draft",
    svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 40">
      <rect width="120" height="40" rx="4" fill="#ca8a04" fill-opacity="0.12" stroke="#ca8a04" stroke-width="1.5"/>
      <text x="60" y="26" text-anchor="middle" font-family="Arial, sans-serif" font-size="14" font-weight="bold" fill="#ca8a04">DRAFT</text>
    </svg>`,
  },
  {
    id: "confidential",
    label: "Confidential",
    svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 140 40">
      <rect width="140" height="40" rx="4" fill="#dc2626" fill-opacity="0.12" stroke="#dc2626" stroke-width="1.5"/>
      <text x="70" y="26" text-anchor="middle" font-family="Arial, sans-serif" font-size="13" font-weight="bold" fill="#dc2626">CONFIDENTIAL</text>
    </svg>`,
  },
  {
    id: "reviewed",
    label: "Reviewed",
    svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 40">
      <rect width="120" height="40" rx="4" fill="#2563eb" fill-opacity="0.12" stroke="#2563eb" stroke-width="1.5"/>
      <text x="60" y="26" text-anchor="middle" font-family="Arial, sans-serif" font-size="14" font-weight="bold" fill="#2563eb">REVIEWED</text>
    </svg>`,
  },
  {
    id: "for_public_release",
    label: "For Public Release",
    svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 170 40">
      <rect width="170" height="40" rx="4" fill="#059669" fill-opacity="0.12" stroke="#059669" stroke-width="1.5"/>
      <text x="85" y="26" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" font-weight="bold" fill="#059669">FOR PUBLIC RELEASE</text>
    </svg>`,
  },
  {
    id: "sign_here",
    label: "Sign Here",
    svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 40">
      <rect width="120" height="40" rx="4" fill="#7c3aed" fill-opacity="0.12" stroke="#7c3aed" stroke-width="1.5"/>
      <text x="60" y="26" text-anchor="middle" font-family="Arial, sans-serif" font-size="14" font-weight="bold" fill="#7c3aed">SIGN HERE</text>
    </svg>`,
  },
];

const AnnotEditHook = {
  mounted() {
    this._viewer = null;
    this._eventBus = null;
    this._previousMode = TYPE_NONE;
    this._wired = false;

    // Sticky note defaults — these are overridden by server-pushed
    // set_sticky_icon / set_sticky_color events from the ribbon controls.
    this._stickyIcon = "note";
    this._stickyColor = "#FFD700";

    // Ink editor defaults
    this._inkColor = [230, 0, 0];   // default red (RGB)
    this._inkThickness = 1;
    this._inkOpacity = 1;

    // Eraser state
    this._eraserActive = false;

    // Shape drawing state (T-106)
    this._shapeMode = null;           // current shape mode string, or null
    this._shapeState = "idle";        // "idle" | "drawing" | "placing"
    this._shapeStart = null;          // {x, y} mousedown start
    this._shapeCurrent = null;        // {x, y} current mouse position
    this._shapeVertices = [];         // [{x, y}, ...] for polygon/cloud/polyline
    this._shapeSvg = null;            // SVG overlay element
    this._shapePageIndex = null;      // page index for the current shape
    this._shapeBind = null;           // bound event handlers reference

    // Shape style defaults — overridden by server-pushed events.
    this._fillColor = "#FF0000";
    this._strokeColor = "#000000";
    this._strokeWidth = 2;
    this._shapeOpacity = 1.0;

    // Stamp state (T-107)
    this._stampMode = null;           // current stamp mode string, or null
    this._stampSvg = null;            // SVG overlay element for stamps
    this._stampSelectedId = null;     // currently selected built-in stamp id
    this._stampCustomData = null;     // custom stamp data (image/text SVG)
    this._stampBind = null;           // bound event handlers

    // File attachment state (T-107)
    this._attachmentMode = false;
    this._attachmentPinSvg = null;    // SVG overlay element for pin
    this._attachmentBind = null;

    // Free-text callout state (T-107)
    this._calloutMode = null;         // current callout mode string
    this._calloutState = "idle";      // "idle" | "placing_anchor" | "sizing" | "editing"
    this._calloutAnchor = null;       // {x, y} leader line anchor point
    this._calloutRect = null;         // {x, y, w, h} text box rect
    this._calloutSvg = null;          // SVG overlay element
    this._calloutBind = null;         // bound event handlers
    this._calloutPageIndex = null;
    this._calloutTextDiv = null;      // contenteditable div for text entry
    this._calloutColor = "#000000";
    this._calloutFontSize = 12;

    // Calibration state (T-108)
    this._calFactor = 1.0;       // scale factor: real-world units per PDF point
    this._calUnit = "pt";         // display unit label
    this._calibrating = false;    // true when in calibration reference-line drawing mode
    this._calRefLine = null;      // {x1,y1,x2,y2} in CSS pixels during calibration draw

    // Common SVG overlay reference shared by stamp/attachment/callout
    this._customSvg = null;

    // Defer wiring until PdfViewerHook has initialised and stored
    // viewer/eventBus references on the shared element.
    this._connect();

    // Server-driven mode switches  (sent from workspace_live.ex
    // when the user clicks an annotation tool in the ribbon).
    this.handleEvent("toggle_annot_mode", ({ mode }) => {
      this._switchMode(mode);
    });

    // Server-driven sticky note icon / colour changes.
    this.handleEvent("set_sticky_icon", ({ icon }) => {
      if (STICKY_ICONS[icon] !== undefined) {
        this._stickyIcon = icon;
      }
    });

    this.handleEvent("set_sticky_color", ({ color }) => {
      this._stickyColor = color;
    });

    // Server-driven ink config changes.
    this.handleEvent("set_ink_color", ({ color }) => {
      this._inkColor = color;
      this._applyInkConfig(PARAMS.INK_COLOR, color);
    });

    this.handleEvent("set_ink_width", ({ width }) => {
      this._inkThickness = width;
      this._applyInkConfig(PARAMS.INK_THICKNESS, width);
    });

    this.handleEvent("set_ink_opacity", ({ opacity }) => {
      this._inkOpacity = opacity;
      this._applyInkConfig(PARAMS.INK_OPACITY, opacity);
    });

    // Server-driven eraser toggle.
    this.handleEvent("toggle_eraser", ({ active }) => {
      this._eraserActive = active;
      // When eraser activates, exit shape mode if active.
      this._cancelShape();
      if (active) {
        this._switchEraserMode();
      } else {
        this._restoreFromEraser();
      }
    });

    // Server-driven shape style config (T-106).
    this.handleEvent("set_fill_color", ({ color }) => {
      this._fillColor = color;
    });

    this.handleEvent("set_stroke_color", ({ color }) => {
      this._strokeColor = color;
    });

    this.handleEvent("set_stroke_width", ({ width }) => {
      this._strokeWidth = width;
    });

    this.handleEvent("set_shape_opacity", ({ opacity }) => {
      this._shapeOpacity = opacity / 100;
    });

    // Server-driven stamp selection (T-107)
    this.handleEvent("select_stamp", ({ stampId, customData }) => {
      this._stampSelectedId = stampId || null;
      this._stampCustomData = customData || null;
    });

    // Server-driven callout color/size changes (T-107)
    this.handleEvent("set_callout_color", ({ color }) => {
      this._calloutColor = color;
    });

    this.handleEvent("set_callout_font_size", ({ size }) => {
      this._calloutFontSize = size;
    });

    // Server-driven calibration data push (T-108)
    this.handleEvent("set_calibration", ({ factor, unit }) => {
      this._calFactor = factor;
      this._calUnit = unit;
    });

    // Enter calibration reference-line drawing mode
    this.handleEvent("begin_calibration_draw", () => {
      this._calibrating = true;
      this._calRefLine = null;
      // Exit any pdf.js editor mode so canvases are interactive
      try {
        this._viewer.annotationEditorMode = { mode: TYPE_NONE };
      } catch (_) { /* ignore */ }
      this._ensureCustomSvg();
      this._bindCalibrationEvents();
    });

    // Cancel calibration mode
    this.handleEvent("cancel_calibration_draw", () => {
      this._calibrating = false;
      this._calRefLine = null;
      this._clearCustomSvg();
      this._unbindCalibrationEvents();
    });

    // Server-driven measure unit update (without recalibrating)
    this.handleEvent("set_measure_unit", ({ unit }) => {
      this._calUnit = unit;
    });
  },

  destroyed() {
    this._cleanupEraser();
    this._teardownShape();
    this._teardownStamp();
    this._teardownAttachment();
    this._teardownCallout();
    this._unbindCalibrationEvents();
    this._cleanupCustomSvg();
    if (this._eventBus && this._onModeChanged) {
      try {
        this._eventBus.off("annotationeditormodechanged", this._onModeChanged);
      } catch (_) { /* already torn down */ }
    }
    if (this._eventBus && this._onStatesChanged) {
      try {
        this._eventBus.off("editingstateschanged", this._onStatesChanged);
      } catch (_) { /* already torn down */ }
    }
    this._viewer = null;
    this._eventBus = null;
  },

  /* ── connection ──────────────────────────────────────────────────── */

  /** Poll until PdfViewerHook has populated this.el._pdfViewer. */
  _connect() {
    const viewer = this.el._pdfViewer;
    const eventBus = this.el._eventBus;

    if (!viewer || !eventBus) {
      this._connectTimer = setTimeout(() => this._connect(), 50);
      return;
    }

    this._viewer = viewer;
    this._eventBus = eventBus;
    this._wireEvents();
  },

  /* ── event bus wiring ────────────────────────────────────────────── */

  _wireEvents() {
    if (this._wired || !this._eventBus) return;
    this._wired = true;

    this._onModeChanged = ({ mode }) => {
      this._previousMode = mode;
      this.pushEvent("annot_mode_changed", { mode });
    };

    this._onStatesChanged = ({ details }) => {
      // When the editor layer transitions from editing to idle,
      // serialise any committed annotations and push to server.
      if (this._shouldCapture(details)) {
        this._captureCommitted();
      }
    };

    this._eventBus.on("annotationeditormodechanged", this._onModeChanged);
    this._eventBus.on("editingstateschanged", this._onStatesChanged);
  },

  /** Determine whether the editing states change indicates committed editors. */
  _shouldCapture(details) {
    // isEditing becomes false when the user commits or cancels an editor.
    // We only care about transitions where editors were actually committed
    // (i.e. was editing and is no longer), and there is content to capture.
    if (details.isEditing) return false;

    // Only capture when the current mode is NOT NONE — a mode switch
    // from an editing mode to NONE is how pdf.js signals commitment.
    // Skip captures triggered by destruction or document close.
    if (this._previousMode === TYPE_NONE) return false;

    return true;
  },

  /* ── mode switching ──────────────────────────────────────────────── */

  /**
   * Switch the annotation editor to the named mode.
   * For shape modes, activates custom SVG drawing instead of pdf.js
   * annotation editor mode.
   * @param {string} modeStr - Mode key
   */
  _switchMode(modeStr) {
    if (!this._viewer) return;

    // Teardown any active custom modes before switching.
    this._deactivateStampMode();
    this._deactivateAttachmentMode();
    this._deactivateCalloutMode();

    // Handle custom (non-native) modes: shapes, stamps, attachment, callout, measures.
    if (CUSTOM_MODES.has(modeStr)) {
      if (SHAPE_MODES.has(modeStr)) {
        this._activateShapeMode(modeStr);
      } else if (STAMP_MODES.has(modeStr)) {
        this._activateStampMode();
      } else if (FILE_ATTACHMENT_MODES.has(modeStr)) {
        this._activateAttachmentMode();
      } else if (FREE_TEXT_CALLOUT_MODES.has(modeStr)) {
        this._activateCalloutMode();
      } else if (MEASURE_MODES.has(modeStr)) {
        this._activateMeasureMode(modeStr);
      }
      return;
    }

    // Tear down shape mode when switching to native.
    this._teardownShape();

    // Non-custom modes: use pdf.js annotation editor.
    const mode = MODE_MAP[modeStr];
    if (mode === undefined) {
      console.warn(`AnnotEditHook: unknown annotation mode "${modeStr}"`);
      return;
    }

    try {
      // Toggle off if already in this mode
      if (this._viewer.annotationEditorMode === mode) {
        this._viewer.annotationEditorMode = { mode: TYPE_NONE };
      } else {
        this._cancelShape();
        this._viewer.annotationEditorMode = { mode };
      }
    } catch (err) {
      console.warn(`AnnotEditHook: failed to switch to mode "${modeStr}":`, err);
    }
  },

  /* ── shape mode (T-106) ──────────────────────────────────────────── */

  /**
   * Activate a shape drawing mode. Exits any pdf.js editor mode,
   * creates an SVG overlay, and listens for mouse/touch events.
   * @param {string} mode - Shape mode: line, arrow, oval, rectangle,
   *                        polygon, cloud, polyline, double_arrow, dimension
   */
  _activateShapeMode(mode) {
    // Toggle off if already in this shape mode.
    if (this._shapeMode === mode) {
      this._deactivateShapeMode();
      return;
    }

    // Cancel any previous shape.
    this._cancelShape();

    // Exit pdf.js annotation editor mode so canvases are interactive.
    try {
      this._viewer.annotationEditorMode = { mode: TYPE_NONE };
    } catch (_) { /* ignore */ }

    this._shapeMode = mode;
    this._shapeState = "idle";
    this._shapeVertices = [];

    // Build SVG overlay if needed.
    this._ensureShapeSvg();

    // Bind mouse/touch handlers.
    this._bindShapeEvents();

    // Notify the server of mode change.
    this.pushEvent("annot_mode_changed", { mode: 0 });
  },

  /** Deactivate shape mode without committing. */
  _deactivateShapeMode() {
    this._cancelShape();
    this._cleanupShapeSvg();
    this._shapeMode = null;
  },

  /** Cancel the current in-progress shape. */
  _cancelShape() {
    this._clearShapePreview();
    this._shapeState = "idle";
    this._shapeStart = null;
    this._shapeCurrent = null;
    this._shapeVertices = [];
    this._shapePageIndex = null;
  },

  /* ── measure modes (T-108) ───────────────────────────────────────── */

  /**
   * Activate a measurement mode. Reuses the shape drawing infrastructure
   * but renders measurement labels and commits computed values.
   * @param {string} mode - "measure_distance", "measure_perimeter", "measure_area"
   */
  _activateMeasureMode(mode) {
    // Toggle off if already in this measure mode.
    if (this._shapeMode === mode) {
      this._deactivateMeasureMode();
      return;
    }

    // Cancel any previous shape/measure.
    this._cancelShape();

    this._shapeMode = mode;
    this._shapeState = "idle";
    this._shapeVertices = [];

    // Exit pdf.js annotation editor mode.
    try {
      this._viewer.annotationEditorMode = { mode: TYPE_NONE };
    } catch (_) { /* ignore */ }

    // Build SVG overlay (shared with shape drawing).
    this._ensureShapeSvg();

    // Bind mouse/touch handlers (reuses shape events).
    this._bindShapeEvents();

    this.pushEvent("annot_mode_changed", { mode: 0 });
  },

  /** Deactivate measure mode without committing. */
  _deactivateMeasureMode() {
    this._cancelShape();
    this._cleanupShapeSvg();
    this._shapeMode = null;
  },

  /* ── calibration drawing (T-108) ──────────────────────────────────── */

  /** Bind calibration reference-line drawing events. */
  _bindCalibrationEvents() {
    this._unbindCalibrationEvents();

    const container = this.el.querySelector("#pdf-viewer-container") ||
                      this.el;

    const handlers = {
      mousedown: (e) => this._onCalPointerDown(e),
      mousemove: (e) => this._onCalPointerMove(e),
      mouseup: (e) => this._onCalPointerUp(e),
    };

    for (const [event, handler] of Object.entries(handlers)) {
      container.addEventListener(event, handler, { passive: false });
    }

    this._calBind = { container, handlers };
  },

  _unbindCalibrationEvents() {
    if (!this._calBind) return;
    const { container, handlers } = this._calBind;
    for (const [event, handler] of Object.entries(handlers)) {
      container.removeEventListener(event, handler);
    }
    this._calBind = null;
  },

  _onCalPointerDown(e) {
    if (!this._calibrating) return;
    e.preventDefault();
    const pos = this._shapePointerPos(e);
    this._calRefLine = { x1: pos.x, y1: pos.y, x2: pos.x, y2: pos.y, pageIndex: pos.pageIndex };
  },

  _onCalPointerMove(e) {
    if (!this._calibrating || !this._calRefLine) return;
    e.preventDefault();
    const pos = this._shapePointerPos(e);
    this._calRefLine.x2 = pos.x;
    this._calRefLine.y2 = pos.y;
    this._renderCalibrationLine();
  },

  _onCalPointerUp(e) {
    if (!this._calibrating || !this._calRefLine) return;
    e.preventDefault();

    // Draw final line
    const pos = this._shapePointerPos(e);
    this._calRefLine.x2 = pos.x;
    this._calRefLine.y2 = pos.y;
    this._renderCalibrationLine();

    // Compute line length in PDF points
    const rl = this._calRefLine;
    const pdfDist = this._measurePdfDistance(
      { x: rl.x1, y: rl.y1 },
      { x: rl.x2, y: rl.y2 },
      rl.pageIndex
    );

    // Notify server that a reference line was drawn
    this.pushEvent("calibration_line_drawn", {
      pdfLength: pdfDist,
      pageIndex: rl.pageIndex,
    });
  },

  /** Render the calibration reference line preview. */
  _renderCalibrationLine() {
    this._clearCustomSvg();
    if (!this._customSvg || !this._calRefLine) return;

    const svg = this._customSvg;
    const ns = "http://www.w3.org/2000/svg";
    const rl = this._calRefLine;

    // Reference line
    const line = document.createElementNS(ns, "line");
    line.setAttribute("x1", rl.x1);
    line.setAttribute("y1", rl.y1);
    line.setAttribute("x2", rl.x2);
    line.setAttribute("y2", rl.y2);
    line.setAttribute("stroke", "#dc2626");
    line.setAttribute("stroke-width", "2");
    line.setAttribute("stroke-dasharray", "6,3");
    svg.appendChild(line);

    // Endpoint dots
    for (const [cx, cy] of [[rl.x1, rl.y1], [rl.x2, rl.y2]]) {
      const dot = document.createElementNS(ns, "circle");
      dot.setAttribute("cx", cx);
      dot.setAttribute("cy", cy);
      dot.setAttribute("r", "4");
      dot.setAttribute("fill", "#dc2626");
      svg.appendChild(dot);
    }

    // Length label at midpoint
    const mx = (rl.x1 + rl.x2) / 2;
    const my = (rl.y1 + rl.y2) / 2;

    const dx = rl.x2 - rl.x1;
    const dy = rl.y2 - rl.y1;
    const len = Math.sqrt(dx * dx + dy * dy);
    const label = `${Math.round(len)} pt`;

    const text = document.createElementNS(ns, "text");
    text.setAttribute("x", mx);
    text.setAttribute("y", my - 10);
    text.setAttribute("fill", "#dc2626");
    text.setAttribute("font-size", "12px");
    text.setAttribute("font-family", "sans-serif");
    text.setAttribute("text-anchor", "middle");
    text.setAttribute("font-weight", "bold");
    text.textContent = label;
    svg.appendChild(text);
  },

  /**
   * Format a measurement value for the display label.
   * Uses the current calibration factor and display unit.
   */
  _formatMeas(valuePdfPoints) {
    if (this._calUnit === "pt") {
      const v = Math.round(valuePdfPoints * 10) / 10;
      return `${v} pt`;
    }
    const scaled = valuePdfPoints * this._calFactor;
    // Format based on unit magnitude
    let decimals;
    if (this._calUnit === "mm") decimals = 1;
    else if (this._calUnit === "cm") decimals = 2;
    else if (this._calUnit === "inches" || this._calUnit === "in") decimals = 2;
    else if (this._calUnit === "m") decimals = 3;
    else decimals = 1;
    const v = scaled.toFixed(decimals);
    return `${v} ${this._calUnit}`;
  },

  /**
   * Get the current page viewport for coordinate conversion.
   * Falls back to null if unavailable.
   */
  _getViewport(pageIndex) {
    if (!this._viewer) return null;
    const pages = this._viewer._pages;
    if (!pages || !pages[pageIndex]) return null;
    const pv = pages[pageIndex];
    return pv.viewport || null;
  },

  /**
   * Convert a CSS pixel position to PDF points using the page viewport.
   */
  _cssToPdfPoint(x, y, pageIndex) {
    const vp = this._getViewport(pageIndex);
    if (!vp) return [x, y];
    const pt = vp.convertToPdfPoint(x, y);
    return pt; // [pdfX, pdfY]
  },

  /**
   * Compute the distance between two CSS pixel points in PDF points
   * (scaled to the measurement unit via calibration).
   */
  _measurePdfDistance(p1, p2, pageIndex) {
    const [px1, py1] = this._cssToPdfPoint(p1.x, p1.y, pageIndex);
    const [px2, py2] = this._cssToPdfPoint(p2.x, p2.y, pageIndex);
    const dx = px2 - px1;
    const dy = py2 - py1;
    return Math.sqrt(dx * dx + dy * dy);
  },

  /**
   * Ensure the SVG overlay element exists in the canvas wrapper.
   * The overlay is a transparent SVG that renders preview shapes.
   */
  _ensureShapeSvg() {
    if (this._shapeSvg && this._shapeSvg.parentNode) return;

    // Find the canvas wrapper inside the pdf-viewer-wrapper.
    const wrapper = this.el.querySelector("#pdf-viewer-container") ||
                    this.el.querySelector("#pdf-viewer-container-left") ||
                    this.el;

    if (!wrapper) return;

    // Remove any stale overlay.
    const old = wrapper.querySelector(".shape-overlay-svg");
    if (old) old.remove();

    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "shape-overlay-svg");
    svg.style.cssText = "position:absolute;top:0;left:0;width:100%;height:100%;overflow:visible;z-index:10;";
    svg.style.pointerEvents = "none"; // events captured at container level
    wrapper.appendChild(svg);
    this._shapeSvg = svg;
  },

  /** Remove the SVG overlay element. */
  _cleanupShapeSvg() {
    if (this._shapeSvg && this._shapeSvg.parentNode) {
      this._shapeSvg.parentNode.removeChild(this._shapeSvg);
    }
    this._shapeSvg = null;
  },

  /** Clear drawn elements from the SVG overlay. */
  _clearShapePreview() {
    if (!this._shapeSvg) return;
    while (this._shapeSvg.firstChild) {
      this._shapeSvg.removeChild(this._shapeSvg.firstChild);
    }
  },

  /* ── shape event handlers ────────────────────────────────────────── */

  /** Bind mouse and touch events for shape drawing. */
  _bindShapeEvents() {
    this._unbindShapeEvents();

    const container = this.el.querySelector("#pdf-viewer-container") ||
                      this.el;

    const handlers = {
      mousedown: (e) => this._onShapePointerDown(e),
      mousemove: (e) => this._onShapePointerMove(e),
      mouseup: (e) => this._onShapePointerUp(e),
      dblclick: (e) => this._onShapeDblClick(e),
      touchstart: (e) => this._onShapeTouchStart(e),
      touchmove: (e) => this._onShapeTouchMove(e),
      touchend: (e) => this._onShapeTouchEnd(e),
    };

    for (const [event, handler] of Object.entries(handlers)) {
      container.addEventListener(event, handler, { passive: false });
    }

    this._shapeBind = { container, handlers };
  },

  /** Remove shape event listeners. */
  _unbindShapeEvents() {
    if (!this._shapeBind) return;
    const { container, handlers } = this._shapeBind;
    for (const [event, handler] of Object.entries(handlers)) {
      container.removeEventListener(event, handler);
    }
    this._shapeBind = null;
  },

  /** Teardown shape resources completely. */
  _teardownShape() {
    this._unbindShapeEvents();
    this._cleanupShapeSvg();
    this._cancelShape();
    this._shapeMode = null;
  },

  /**
   * Get the pointer position relative to the pdf-viewer-container.
   * Returns {x, y, pageIndex} where pageIndex is determined by
   * which PDF page the pointer is over.
   */
  _shapePointerPos(e) {
    const container = this.el.querySelector("#pdf-viewer-container") ||
                      this.el;
    const rect = container.getBoundingClientRect();
    const clientX = e.clientX;
    const clientY = e.clientY;

    const x = clientX - rect.left;
    const y = clientY - rect.top;

    // Find which page the pointer is over.
    let pageIndex = 0;
    const pages = this._viewer && this._viewer._pages;
    if (pages) {
      for (let i = 0; i < pages.length; i++) {
        const pv = pages[i];
        if (!pv || !pv.div) continue;
        const pr = pv.div.getBoundingClientRect();
        if (clientX >= pr.left && clientX <= pr.right &&
            clientY >= pr.top && clientY <= pr.bottom) {
          pageIndex = i;
          break;
        }
      }
    }

    return { x, y, pageIndex };
  },

  /** Handle pointer down for shape drawing (line/arrow/oval/rect). */
  _onShapePointerDown(e) {
    if (!this._shapeMode) return;
    e.preventDefault();

    const pos = this._shapePointerPos(e);
    this._shapePageIndex = pos.pageIndex;
    this._shapeStart = { x: pos.x, y: pos.y };
    this._shapeCurrent = { x: pos.x, y: pos.y };

    // For polygon, cloud, polyline: this is a vertex click, not a drag start.
    if (this._isClickPlacementMode()) {
      // Add vertex (handled in _onShapePointerUp to differentiate from dblclick)
      return;
    }

    this._shapeState = "drawing";
  },

  /** Handle pointer move for shape drawing preview. */
  _onShapePointerMove(e) {
    if (!this._shapeMode) return;
    if (this._shapeState !== "drawing") return;
    e.preventDefault();

    const pos = this._shapePointerPos(e);
    this._shapeCurrent = { x: pos.x, y: pos.y };

    this._renderShapePreview();
  },

  /** Handle pointer up for shape drawing completion. */
  _onShapePointerUp(e) {
    if (!this._shapeMode) return;
    e.preventDefault();

    if (this._isClickPlacementMode()) {
      // Polygon/cloud/polyline: click to place a vertex.
      const pos = this._shapePointerPos(e);
      this._shapePageIndex = this._shapePageIndex != null ? this._shapePageIndex : pos.pageIndex;
      this._shapeVertices.push({ x: pos.x, y: pos.y });
      this._renderShapePreview();
      this._shapeState = "placing";
      return;
    }

    if (this._shapeState !== "drawing") return;

    // Commit the shape immediately on mouseup.
    this._commitShape();
  },

  /** Handle double-click for polygon/cloud/polyline completion. */
  _onShapeDblClick(e) {
    if (!this._shapeMode || !this._isClickPlacementMode()) return;
    e.preventDefault();

    // Remove the last vertex if it was just placed from the double-click
    // (the first click of the double-click already added a vertex).
    if (this._shapeVertices.length > 2) {
      this._shapeVertices.pop();
    }

    if (this._shapeVertices.length >= 2) {
      this._commitShape();
    } else {
      this._cancelShape();
    }
  },

  /** Handle touch start — translate to pointer down. */
  _onShapeTouchStart(e) {
    if (!this._shapeMode) return;
    e.preventDefault();
    const touch = e.touches[0];
    if (!touch) return;
    this._onShapePointerDown(touch);
  },

  /** Handle touch move — translate to pointer move. */
  _onShapeTouchMove(e) {
    if (!this._shapeMode) return;
    e.preventDefault();
    const touch = e.touches[0];
    if (!touch) return;
    this._onShapePointerMove(touch);
  },

  /** Handle touch end — translate to pointer up. */
  _onShapeTouchEnd(e) {
    if (!this._shapeMode) return;
    e.preventDefault();
    // Use the last known position.
    this._onShapePointerUp(e);
  },

  /** Check if current mode uses click-to-place-vertex drawing. */
  _isClickPlacementMode() {
    return this._shapeMode === "polygon" ||
           this._shapeMode === "cloud" ||
           this._shapeMode === "polyline";
  },

  /* ── shape rendering ─────────────────────────────────────────────── */

  /**
   * Render the current shape preview on the SVG overlay.
   * Different rendering per shape type.
   */
  _renderShapePreview() {
    this._clearShapePreview();
    if (!this._shapeSvg || !this._shapeStart) return;

    const svg = this._shapeSvg;
    const ns = "http://www.w3.org/2000/svg";

    switch (this._shapeMode) {
      case "line":
      case "arrow":
      case "double_arrow":
      case "dimension":
      case "measure_distance": {
        this._renderLineShape(svg, ns);
        break;
      }
      case "oval": {
        this._renderOvalShape(svg, ns);
        break;
      }
      case "rectangle":
      case "whiteout": {
        this._renderRectShape(svg, ns);
        break;
      }
      case "polygon":
      case "cloud":
      case "polyline":
      case "measure_perimeter":
      case "measure_area": {
        this._renderVertexShape(svg, ns);
        break;
      }
    }
  },

  /** Render a line/arrow based shape (line, arrow, double_arrow, dimension, measure_distance). */
  _renderLineShape(svg, ns) {
    const s = this._shapeStart;
    const c = this._shapeCurrent || s;
    if (!s || !c) return;
    const strokeW = this._strokeWidth;
    const color = this._strokeColor;
    const opacity = this._shapeOpacity;
    const isMeasureDist = this._shapeMode === "measure_distance";

    // Main line
    const line = document.createElementNS(ns, "line");
    line.setAttribute("x1", s.x);
    line.setAttribute("y1", s.y);
    line.setAttribute("x2", c.x);
    line.setAttribute("y2", c.y);
    line.setAttribute("stroke", color);
    line.setAttribute("stroke-width", strokeW);
    line.setAttribute("opacity", opacity);
    line.setAttribute("stroke-linecap", "round");
    svg.appendChild(line);

    // Angle and length for arrowheads
    const dx = c.x - s.x;
    const dy = c.y - s.y;
    const angle = Math.atan2(dy, dx);
    const headLen = 10 + strokeW * 2;

    if (this._shapeMode === "arrow" || this._shapeMode === "double_arrow") {
      // Arrowhead at end
      this._addArrowhead(svg, ns, c.x, c.y, angle, headLen, color, opacity);
      if (this._shapeMode === "double_arrow") {
        // Arrowhead at start
        this._addArrowhead(svg, ns, s.x, s.y, angle + Math.PI, headLen, color, opacity);
      }
    }

    if (isMeasureDist) {
      // Measurement label at line midpoint
      const midX = (s.x + c.x) / 2;
      const midY = (s.y + c.y) / 2;
      const perpAngle = angle + Math.PI / 2;
      const extOffset = 14;

      // Compute distance in PDF points and format
      const pdfDist = this._measurePdfDistance(s, c, this._shapePageIndex);
      const label = this._formatMeas(pdfDist);

      // Label background pill
      const labelW = label.length * 6 + 10;
      const labelH = 18;
      const lx = midX + Math.cos(perpAngle) * extOffset - labelW / 2;
      const ly = midY + Math.sin(perpAngle) * extOffset - labelH / 2;

      const bg = document.createElementNS(ns, "rect");
      bg.setAttribute("x", lx);
      bg.setAttribute("y", ly);
      bg.setAttribute("width", labelW);
      bg.setAttribute("height", labelH);
      bg.setAttribute("rx", "4");
      bg.setAttribute("fill", "rgba(255,255,255,0.9)");
      bg.setAttribute("stroke", color);
      bg.setAttribute("stroke-width", "1");
      bg.setAttribute("opacity", opacity);
      svg.appendChild(bg);

      const text = document.createElementNS(ns, "text");
      text.setAttribute("x", midX + Math.cos(perpAngle) * extOffset);
      text.setAttribute("y", midY + Math.sin(perpAngle) * extOffset + 4);
      text.setAttribute("fill", color);
      text.setAttribute("font-size", "11px");
      text.setAttribute("opacity", opacity);
      text.setAttribute("font-family", "sans-serif");
      text.setAttribute("text-anchor", "middle");
      text.textContent = label;
      svg.appendChild(text);
    }

    if (this._shapeMode === "dimension") {
      // Extension lines and measurement label
      const midX = (s.x + c.x) / 2;
      const midY = (s.y + c.y) / 2;
      const perpAngle = angle + Math.PI / 2;
      const extLen = 8;

      // Start extension
      const ext1 = document.createElementNS(ns, "line");
      ext1.setAttribute("x1", s.x + Math.cos(perpAngle) * extLen);
      ext1.setAttribute("y1", s.y + Math.sin(perpAngle) * extLen);
      ext1.setAttribute("x2", s.x - Math.cos(perpAngle) * extLen);
      ext1.setAttribute("y2", s.y - Math.sin(perpAngle) * extLen);
      ext1.setAttribute("stroke", color);
      ext1.setAttribute("stroke-width", 1);
      ext1.setAttribute("opacity", opacity * 0.6);
      svg.appendChild(ext1);

      // End extension
      const ext2 = document.createElementNS(ns, "line");
      ext2.setAttribute("x1", c.x + Math.cos(perpAngle) * extLen);
      ext2.setAttribute("y1", c.y + Math.sin(perpAngle) * extLen);
      ext2.setAttribute("x2", c.x - Math.cos(perpAngle) * extLen);
      ext2.setAttribute("y2", c.y - Math.sin(perpAngle) * extLen);
      ext2.setAttribute("stroke", color);
      ext2.setAttribute("stroke-width", 1);
      ext2.setAttribute("opacity", opacity * 0.6);
      svg.appendChild(ext2);

      // Tick marks at ends
      for (const pt of [s, c]) {
        const tick = document.createElementNS(ns, "line");
        tick.setAttribute("x1", pt.x - Math.cos(perpAngle) * (extLen + 3));
        tick.setAttribute("y1", pt.y - Math.sin(perpAngle) * (extLen + 3));
        tick.setAttribute("x2", pt.x + Math.cos(perpAngle) * (extLen + 3));
        tick.setAttribute("y2", pt.y + Math.sin(perpAngle) * (extLen + 3));
        tick.setAttribute("stroke", color);
        tick.setAttribute("stroke-width", 1);
        tick.setAttribute("opacity", opacity);
        svg.appendChild(tick);
      }

      // Distance label
      const dist = Math.round(Math.sqrt(dx * dx + dy * dy));
      const text = document.createElementNS(ns, "text");
      text.setAttribute("x", midX + Math.cos(perpAngle) * (extLen + 12));
      text.setAttribute("y", midY + Math.sin(perpAngle) * (extLen + 12));
      text.setAttribute("fill", color);
      text.setAttribute("font-size", "10px");
      text.setAttribute("opacity", opacity);
      text.setAttribute("font-family", "sans-serif");
      text.textContent = `${dist} pt`;
      svg.appendChild(text);
    }
  },

  /** Helper: add an arrowhead polygon at the given position and angle. */
  _addArrowhead(svg, ns, x, y, angle, size, color, opacity) {
    const arrow = document.createElementNS(ns, "polygon");
    const p1x = x + Math.cos(angle) * size;
    const p1y = y + Math.sin(angle) * size;
    const spread = Math.PI / 6;
    const p2x = x - Math.cos(angle - spread) * size * 0.7;
    const p2y = y - Math.sin(angle - spread) * size * 0.7;
    const p3x = x - Math.cos(angle + spread) * size * 0.7;
    const p3y = y - Math.sin(angle + spread) * size * 0.7;
    arrow.setAttribute("points", `${p1x},${p1y} ${p2x},${p2y} ${p3x},${p3y}`);
    arrow.setAttribute("fill", color);
    arrow.setAttribute("opacity", opacity);
    svg.appendChild(arrow);
  },

  /** Render an oval/ellipse preview shape. */
  _renderOvalShape(svg, ns) {
    const s = this._shapeStart;
    const c = this._shapeCurrent || s;
    if (!s || !c) return;

    const cx = (s.x + c.x) / 2;
    const cy = (s.y + c.y) / 2;
    const rx = Math.abs(c.x - s.x) / 2;
    const ry = Math.abs(c.y - s.y) / 2;

    const ellipse = document.createElementNS(ns, "ellipse");
    ellipse.setAttribute("cx", cx);
    ellipse.setAttribute("cy", cy);
    ellipse.setAttribute("rx", Math.max(rx, 1));
    ellipse.setAttribute("ry", Math.max(ry, 1));
    ellipse.setAttribute("fill", this._fillColor);
    ellipse.setAttribute("fill-opacity", this._shapeOpacity * 0.3);
    ellipse.setAttribute("stroke", this._strokeColor);
    ellipse.setAttribute("stroke-width", this._strokeWidth);
    ellipse.setAttribute("stroke-opacity", this._shapeOpacity);
    svg.appendChild(ellipse);
  },

  /** Render a rectangle preview shape. */
  _renderRectShape(svg, ns) {
    const s = this._shapeStart;
    const c = this._shapeCurrent || s;
    if (!s || !c) return;

    const x = Math.min(s.x, c.x);
    const y = Math.min(s.y, c.y);
    const w = Math.abs(c.x - s.x);
    const h = Math.abs(c.y - s.y);

    if (w < 1 && h < 1) return;

    const isWhiteout = this._shapeMode === "whiteout";
    const fillColor = isWhiteout ? "#FFFFFF" : this._fillColor;
    const fillOpacity = isWhiteout ? 1.0 : this._shapeOpacity * 0.3;
    const strokeColor = isWhiteout ? "#E5E7EB" : this._strokeColor;
    const strokeWidth = isWhiteout ? 1 : this._strokeWidth;
    const strokeOpacity = isWhiteout ? 1.0 : this._shapeOpacity;
    const strokeDash = isWhiteout ? "4,2" : null;

    const rect = document.createElementNS(ns, "rect");
    rect.setAttribute("x", x);
    rect.setAttribute("y", y);
    rect.setAttribute("width", Math.max(w, 1));
    rect.setAttribute("height", Math.max(h, 1));
    rect.setAttribute("fill", fillColor);
    rect.setAttribute("fill-opacity", fillOpacity);
    rect.setAttribute("stroke", strokeColor);
    rect.setAttribute("stroke-width", strokeWidth);
    rect.setAttribute("stroke-opacity", strokeOpacity);
    if (strokeDash) {
      rect.setAttribute("stroke-dasharray", strokeDash);
    }
    svg.appendChild(rect);
  },

  /** Render a polygon/cloud/polyline vertex-based preview. */
  _renderVertexShape(svg, ns) {
    const verts = this._shapeVertices;
    if (verts.length === 0) return;

    const isClosed = this._shapeMode === "polygon" || this._shapeMode === "cloud" ||
                     this._shapeMode === "measure_perimeter" || this._shapeMode === "measure_area";
    const isPolyline = this._shapeMode === "polyline";
    const isMeasurePerimeter = this._shapeMode === "measure_perimeter";
    const isMeasureArea = this._shapeMode === "measure_area";
    const isMeasureVerts = isMeasurePerimeter || isMeasureArea;

    // Draw connecting lines
    if (verts.length >= 2) {
      // Draw all segments
      const pointsStr = verts.map(v => `${v.x},${v.y}`).join(" ");

      if (isClosed && verts.length >= 3) {
        // Closed shape: polygon or cloud
        const poly = document.createElementNS(ns, "polygon");
        poly.setAttribute("points", pointsStr);
        poly.setAttribute("fill", this._fillColor);
        poly.setAttribute("fill-opacity", isMeasureVerts ? 0.08 : this._shapeOpacity * 0.3);
        poly.setAttribute("stroke", this._strokeColor);
        poly.setAttribute("stroke-width", this._strokeWidth);
        poly.setAttribute("stroke-opacity", this._shapeOpacity);
        poly.setAttribute("stroke-linejoin", "round");
        svg.appendChild(poly);

        if (this._shapeMode === "cloud") {
          // Add scalloped edge circles along each segment for cloud effect
          for (let i = 0; i < verts.length; i++) {
            const v1 = verts[i];
            const v2 = verts[(i + 1) % verts.length];
            this._addCloudScallops(svg, ns, v1, v2);
          }
        }

        // Edge measurement labels for measure_perimeter and measure_area
        if (isMeasureVerts) {
          let totalPdfDist = 0;
          for (let i = 0; i < verts.length; i++) {
            const v1 = verts[i];
            const v2 = verts[(i + 1) % verts.length];
            const pdfDist = this._measurePdfDistance(v1, v2, this._shapePageIndex);
            totalPdfDist += pdfDist;

            // Label at edge midpoint, offset perpendicular
            const mx = (v1.x + v2.x) / 2;
            const my = (v1.y + v2.y) / 2;
            const dx = v2.x - v1.x;
            const dy = v2.y - v1.y;
            const eAngle = Math.atan2(dy, dx);
            const perpAngle = eAngle + Math.PI / 2;
            const off = 12;

            const edgeLabel = this._formatMeas(pdfDist);
            const et = document.createElementNS(ns, "text");
            et.setAttribute("x", mx + Math.cos(perpAngle) * off);
            et.setAttribute("y", my + Math.sin(perpAngle) * off);
            et.setAttribute("fill", this._strokeColor);
            et.setAttribute("font-size", "9px");
            et.setAttribute("opacity", this._shapeOpacity);
            et.setAttribute("font-family", "sans-serif");
            et.setAttribute("text-anchor", "middle");
            et.textContent = edgeLabel;
            svg.appendChild(et);
          }

          // Total label for perimeter, or area + perimeter for area
          const centerX = verts.reduce((s, v) => s + v.x, 0) / verts.length;
          const centerY = verts.reduce((s, v) => s + v.y, 0) / verts.length;

          if (isMeasurePerimeter) {
            // Show total perimeter at centroid
            const totalLabel = "P: " + this._formatMeas(totalPdfDist);
            const tb = document.createElementNS(ns, "rect");
            const tw = totalLabel.length * 6 + 12;
            const th = 20;
            tb.setAttribute("x", centerX - tw / 2);
            tb.setAttribute("y", centerY - th / 2);
            tb.setAttribute("width", tw);
            tb.setAttribute("height", th);
            tb.setAttribute("rx", "4");
            tb.setAttribute("fill", "rgba(255,255,255,0.92)");
            tb.setAttribute("stroke", this._strokeColor);
            tb.setAttribute("stroke-width", "1");
            tb.setAttribute("opacity", this._shapeOpacity);
            svg.appendChild(tb);

            const tt = document.createElementNS(ns, "text");
            tt.setAttribute("x", centerX);
            tt.setAttribute("y", centerY + 4);
            tt.setAttribute("fill", this._strokeColor);
            tt.setAttribute("font-size", "11px");
            tt.setAttribute("opacity", this._shapeOpacity);
            tt.setAttribute("font-family", "sans-serif");
            tt.setAttribute("font-weight", "bold");
            tt.setAttribute("text-anchor", "middle");
            tt.textContent = totalLabel;
            svg.appendChild(tt);
          }

          if (isMeasureArea) {
            // Compute area in PDF points via shoelace
            const pts = verts.map(v => this._cssToPdfPoint(v.x, v.y, this._shapePageIndex));
            let areaSum = 0;
            for (let i = 0; i < pts.length; i++) {
              const [x1, y1] = pts[i];
              const [x2, y2] = pts[(i + 1) % pts.length];
              areaSum += x1 * y2 - x2 * y1;
            }
            const areaPdf = Math.abs(areaSum) / 2;
            const totalPdf = totalPdfDist;

            const areaLabel = "A: " + this._formatMeas(areaPdf) + (this._calUnit === "pt" ? "²" : "²");
            const periLabel = "P: " + this._formatMeas(totalPdf);

            // Two-line label at centroid
            const lines = [areaLabel, periLabel];
            const maxW = Math.max(...lines.map(l => l.length)) * 6.5 + 12;
            const lineH = 18;
            const boxH = lines.length * lineH + 6;

            const ab = document.createElementNS(ns, "rect");
            ab.setAttribute("x", centerX - maxW / 2);
            ab.setAttribute("y", centerY - boxH / 2);
            ab.setAttribute("width", maxW);
            ab.setAttribute("height", boxH);
            ab.setAttribute("rx", "4");
            ab.setAttribute("fill", "rgba(255,255,255,0.92)");
            ab.setAttribute("stroke", this._strokeColor);
            ab.setAttribute("stroke-width", "1");
            ab.setAttribute("opacity", this._shapeOpacity);
            svg.appendChild(ab);

            for (let i = 0; i < lines.length; i++) {
              const t = document.createElementNS(ns, "text");
              t.setAttribute("x", centerX);
              t.setAttribute("y", centerY - boxH / 2 + 14 + i * lineH);
              t.setAttribute("fill", this._strokeColor);
              t.setAttribute("font-size", "11px");
              t.setAttribute("opacity", this._shapeOpacity);
              t.setAttribute("font-family", "sans-serif");
              t.setAttribute("font-weight", i === 0 ? "bold" : "normal");
              t.setAttribute("text-anchor", "middle");
              t.textContent = lines[i];
              svg.appendChild(t);
            }
          }
        }
      } else {
        // Open shape: polyline
        const polyline = document.createElementNS(ns, "polyline");
        polyline.setAttribute("points", pointsStr);
        if (isPolyline) {
          polyline.setAttribute("fill", "none");
        } else {
          polyline.setAttribute("fill", this._fillColor);
          polyline.setAttribute("fill-opacity", this._shapeOpacity * 0.3);
        }
        polyline.setAttribute("stroke", this._strokeColor);
        polyline.setAttribute("stroke-width", this._strokeWidth);
        polyline.setAttribute("stroke-opacity", this._shapeOpacity);
        polyline.setAttribute("stroke-linejoin", "round");
        polyline.setAttribute("stroke-linecap", "round");
        svg.appendChild(polyline);
      }
    }

    // Draw vertex dots
    for (const v of verts) {
      const dot = document.createElementNS(ns, "circle");
      dot.setAttribute("cx", v.x);
      dot.setAttribute("cy", v.y);
      dot.setAttribute("r", Math.max(3, this._strokeWidth + 1));
      dot.setAttribute("fill", this._strokeColor);
      dot.setAttribute("opacity", this._shapeOpacity);
      svg.appendChild(dot);
    }

    // Draw preview line to current mouse position if placing
    if (this._shapeCurrent && verts.length > 0) {
      const last = verts[verts.length - 1];
      const cur = this._shapeCurrent;
      const preview = document.createElementNS(ns, "line");
      preview.setAttribute("x1", last.x);
      preview.setAttribute("y1", last.y);
      preview.setAttribute("x2", cur.x);
      preview.setAttribute("y2", cur.y);
      preview.setAttribute("stroke", this._strokeColor);
      preview.setAttribute("stroke-width", this._strokeWidth);
      preview.setAttribute("opacity", this._shapeOpacity * 0.5);
      preview.setAttribute("stroke-dasharray", "5,3");
      svg.appendChild(preview);
    }
  },

  /** Add cloud scallop arcs along a segment between two vertices. */
  _addCloudScallops(svg, ns, v1, v2) {
    const dx = v2.x - v1.x;
    const dy = v2.y - v1.y;
    const segLen = Math.sqrt(dx * dx + dy * dy);
    if (segLen < 1) return;

    // Place scallops at intervals along the segment
    const scallopRadius = Math.max(6, this._strokeWidth * 3);
    const step = scallopRadius * 1.5;
    const count = Math.max(1, Math.floor(segLen / step));

    for (let i = 0; i <= count; i++) {
      const t = i / count;
      const cx = v1.x + dx * t;
      const cy = v1.y + dy * t;
      const circle = document.createElementNS(ns, "circle");
      circle.setAttribute("cx", cx);
      circle.setAttribute("cy", cy);
      circle.setAttribute("r", scallopRadius);
      circle.setAttribute("fill", "none");
      circle.setAttribute("stroke", this._strokeColor);
      circle.setAttribute("stroke-width", this._strokeWidth);
      circle.setAttribute("opacity", this._shapeOpacity);
      svg.appendChild(circle);
    }
  },

  /* ── shape serialisation ─────────────────────────────────────────── */

  /**
   * Commit the current shape: serialise to path_data, compute bounding rect,
   * and push annot_committed to the server.
   */
  _commitShape() {
    if (!this._shapeMode || !this._shapeStart) return;

    const mode = this._shapeMode;

    // Serialise path_data per shape type.
    const pathData = this._serialisePathData();
    if (!pathData) {
      this._cancelShape();
      return;
    }

    // Compute bounding rect in CSS coordinates.
    const rect = this._computeBoundingRect();
    if (!rect) {
      this._cancelShape();
      return;
    }

    // Convert to PDF coordinates.
    const pageIndex = this._shapePageIndex || 0;
    const pageViews = this._buildPageViews();
    const data = {
      id: `shape_${Date.now()}`,
      pageIndex,
      pathData,
      rect,
      fillColor: this._fillColor,
      strokeColor: this._strokeColor,
      strokeWidth: this._strokeWidth,
      opacity: Math.round(this._shapeOpacity * 100),
    };

    // Whiteout: force opaque white fill, no visible stroke.
    if (mode === "whiteout") {
      data.fillColor = "#FFFFFF";
      data.strokeColor = "#FFFFFF";
      data.strokeWidth = 0;
      data.opacity = 100;
    }

    // Measure modes: include computed measurement values in PDF points.
    if (this._isMeasureMode(mode)) {
      data.measurement = this._computeMeasurement(mode);
      data.calFactor = this._calFactor;
      data.calUnit = this._calUnit;
    }

    // Convert rect to PDF points if possible.
    const converted = this._convertCoordinates(data.id, data, pageViews);
    data.rectPdf = converted.rectPdf;

    // Push to server.
    this.pushEvent("annot_committed", { type: mode, data });

    // Reset state.
    this._cancelShape();

    // Keep shape mode active so the user can draw another shape.
    this._shapeState = "idle";
  },

  /** Check if a mode is a measurement mode. */
  _isMeasureMode(mode) {
    return mode === "measure_distance" || mode === "measure_perimeter" || mode === "measure_area";
  },

  /** Compute measurement values in PDF points for the current shape. */
  _computeMeasurement(mode) {
    const pageIndex = this._shapePageIndex || 0;

    if (mode === "measure_distance") {
      const s = this._shapeStart;
      const c = this._shapeCurrent || s;
      const dist = this._measurePdfDistance(s, c, pageIndex);
      return { distancePdf: dist, perimeterPdf: dist, type: "distance" };
    }

    // Perimeter or area — compute from vertices
    const verts = this._shapeVertices;
    if (verts.length < 2) return null;

    // Convert all vertices to PDF points
    const pts = verts.map(v => this._cssToPdfPoint(v.x, v.y, pageIndex));

    // Compute edge distances
    let totalDist = 0;
    const edges = [];
    for (let i = 0; i < pts.length; i++) {
      const [x1, y1] = pts[i];
      const [x2, y2] = pts[(i + 1) % pts.length];
      const d = Math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2);
      edges.push(d);
      totalDist += d;
    }

    if (mode === "measure_perimeter") {
      return { edges, perimeterPdf: totalDist, type: "perimeter" };
    }

    if (mode === "measure_area") {
      // Shoelace
      let area = 0;
      for (let i = 0; i < pts.length; i++) {
        const [x1, y1] = pts[i];
        const [x2, y2] = pts[(i + 1) % pts.length];
        area += x1 * y2 - x2 * y1;
      }
      area = Math.abs(area) / 2;
      return { edges, perimeterPdf: totalDist, areaPdf: area, type: "area" };
    }

    return null;
  },

  /**
   * Serialise path data for the current shape.
   * Returns the appropriate format per shape type.
   */
  _serialisePathData() {
    const mode = this._shapeMode;
    const s = this._shapeStart;
    const c = this._shapeCurrent || s;

    switch (mode) {
      case "line":
      case "arrow":
      case "double_arrow":
      case "dimension":
      case "measure_distance":
        // [x1, y1, x2, y2] start/end points
        return [s.x, s.y, c.x, c.y];

      case "oval":
      case "rectangle": {
        // [x, y, w, h] bounding box
        const x = Math.min(s.x, c.x);
        const y = Math.min(s.y, c.y);
        const w = Math.abs(c.x - s.x);
        const h = Math.abs(c.y - s.y);
        return [x, y, w, h];
      }

      case "polygon":
      case "cloud":
      case "polyline":
      case "measure_perimeter":
      case "measure_area": {
        // [[x1,y1], [x2,y2], ...] vertex array
        const verts = this._shapeVertices.map(v => [v.x, v.y]);
        if (mode === "cloud") {
          // Store cloud flag alongside vertices
          return { vertices: verts, cloud: true };
        }
        return verts;
      }

      default:
        return null;
    }
  },

  /**
   * Compute the bounding rectangle from shape data.
   * Returns [x, y, w, h] or null.
   */
  _computeBoundingRect() {
    const mode = this._shapeMode;
    const s = this._shapeStart;
    const c = this._shapeCurrent || s;

    if (mode === "line" || mode === "arrow" || mode === "double_arrow" || mode === "dimension" || mode === "measure_distance") {
      return [
        Math.min(s.x, c.x),
        Math.min(s.y, c.y),
        Math.abs(c.x - s.x),
        Math.abs(c.y - s.y),
      ];
    }

    if (mode === "oval" || mode === "rectangle") {
      return [
        Math.min(s.x, c.x),
        Math.min(s.y, c.y),
        Math.abs(c.x - s.x),
        Math.abs(c.y - s.y),
      ];
    }

    if (mode === "polygon" || mode === "cloud" || mode === "polyline" || mode === "measure_perimeter" || mode === "measure_area") {
      if (this._shapeVertices.length === 0) return null;
      const xs = this._shapeVertices.map(v => v.x);
      const ys = this._shapeVertices.map(v => v.y);
      const minX = Math.min(...xs);
      const minY = Math.min(...ys);
      return [
        minX,
        minY,
        Math.max(...xs) - minX,
        Math.max(...ys) - minY,
      ];
    }

    return null;
  },

  /** Build a Map<number, PDFPageView> from the current viewer pages. */
  _buildPageViews() {
    const pageViews = new Map();
    const pages = this._viewer && this._viewer._pages;
    if (pages) {
      for (let i = 0; i < pages.length; i++) {
        if (pages[i]) pageViews.set(i, pages[i]);
      }
    }
    return pageViews;
  },

  /* ── eraser ───────────────────────────────────────────────────────── */

  /** Switch to eraser mode: exit active drawing so annotations are selectable. */
  _switchEraserMode() {
    if (!this._viewer) return;
    this._cancelShape();

    try {
      // Exit ink/drawing mode so existing annotation elements are interactable
      // through the annotation layer. We keep editing context alive.
      this._viewer.annotationEditorMode = { mode: TYPE_NONE };
    } catch (err) {
      console.warn("AnnotEditHook: failed to enter eraser mode:", err);
    }
  },

  /** Restore ink drawing mode after eraser deactivation. */
  _restoreFromEraser() {
    if (!this._viewer) return;

    try {
      this._viewer.annotationEditorMode = { mode: MODE_MAP.ink };
    } catch (err) {
      console.warn("AnnotEditHook: failed to restore ink mode after eraser:", err);
    }
  },

  /** Clean up eraser click listeners. */
  _cleanupEraser() {
    this._eraserActive = false;
  },

  /* ── stamp mode (T-107) ──────────────────────────────────────────── */

  /**
   * Activate stamp placement mode. Click on the page to place
   * the currently selected built-in or custom stamp.
   */
  _activateStampMode() {
    // Toggle off if already in stamp mode.
    if (this._stampMode === "stamp") {
      this._deactivateStampMode();
      return;
    }

    // Exit pdf.js annotation editor mode.
    try {
      this._viewer.annotationEditorMode = { mode: TYPE_NONE };
    } catch (_) { /* ignore */ }

    this._stampMode = "stamp";

    // Ensure custom SVG overlay.
    this._ensureCustomSvg();

    // Bind click handler.
    this._bindStampEvents();

    this.pushEvent("annot_mode_changed", { mode: 0 });
  },

  _deactivateStampMode() {
    this._unbindStampEvents();
    this._stampMode = null;
  },

  _bindStampEvents() {
    this._unbindStampEvents();

    const container = this.el.querySelector("#pdf-viewer-container") ||
                      this.el;

    const handler = (e) => this._onStampClick(e);
    container.addEventListener("click", handler);
    this._stampBind = { container, handler };
  },

  _unbindStampEvents() {
    if (!this._stampBind) return;
    const { container, handler } = this._stampBind;
    container.removeEventListener("click", handler);
    this._stampBind = null;
  },

  _teardownStamp() {
    this._unbindStampEvents();
    this._stampMode = null;
  },

  /**
   * Handle click to place a stamp.
   */
  _onStampClick(e) {
    if (!this._stampMode) return;
    e.preventDefault();

    const pos = this._shapePointerPos(e);
    const pageIndex = pos.pageIndex;

    // Determine stamp SVG content.
    let stampSvgContent;
    let stampId;

    if (this._stampCustomData) {
      // Custom stamp (image/text from user settings)
      stampSvgContent = this._stampCustomData;
      stampId = "custom";
    } else {
      // Built-in stamp
      const stampDef = BUILTIN_STAMPS.find(s => s.id === this._stampSelectedId) || BUILTIN_STAMPS[0];
      stampSvgContent = stampDef.svg;
      stampId = stampDef.id;
    }

    // Render stamp preview at click location.
    this._clearCustomSvg();
    if (!this._customSvg) return;

    const ns = "http://www.w3.org/2000/svg";
    const wrapper = document.createElementNS(ns, "g");
    wrapper.setAttribute("transform", `translate(${pos.x - 60}, ${pos.y - 20})`);

    // Parse the stamp SVG and embed it.
    const tempContainer = document.createElement("div");
    tempContainer.innerHTML = stampSvgContent;
    const srcSvg = tempContainer.querySelector("svg");
    if (srcSvg) {
      for (let i = 0; i < srcSvg.childNodes.length; i++) {
        const child = srcSvg.childNodes[i].cloneNode(true);
        wrapper.appendChild(child);
      }
    }

    this._customSvg.appendChild(wrapper);

    // Compute bounding rect.
    const w = 120;
    const h = 40;
    const rect = [pos.x - 60, pos.y - 20, w, h];

    // Convert coordinates and push to server.
    const pageViews = this._buildPageViews();
    const data = {
      id: `stamp_${Date.now()}`,
      pageIndex,
      stampId,
      stampSvg: stampSvgContent,
      rect,
    };
    const converted = this._convertCoordinates(data.id, data, pageViews);
    data.rectPdf = converted.rectPdf;

    this.pushEvent("annot_committed", { type: "stamp", data });

    // Fade out preview after a brief display.
    setTimeout(() => this._clearCustomSvg(), 1500);
  },

  /* ── file attachment mode (T-107) ─────────────────────────────────── */

  /**
   * Activate file attachment placement mode. Click on the page to
   * place a pin icon, then a file picker opens.
   */
  _activateAttachmentMode() {
    if (this._attachmentMode) {
      this._deactivateAttachmentMode();
      return;
    }

    try {
      this._viewer.annotationEditorMode = { mode: TYPE_NONE };
    } catch (_) { /* ignore */ }

    this._attachmentMode = true;
    this._ensureCustomSvg();
    this._bindAttachmentEvents();

    this.pushEvent("annot_mode_changed", { mode: 0 });
  },

  _deactivateAttachmentMode() {
    this._unbindAttachmentEvents();
    this._attachmentMode = false;
  },

  _bindAttachmentEvents() {
    this._unbindAttachmentEvents();

    const container = this.el.querySelector("#pdf-viewer-container") ||
                      this.el;

    const handler = (e) => this._onAttachmentClick(e);
    container.addEventListener("click", handler);
    this._attachmentBind = { container, handler };
  },

  _unbindAttachmentEvents() {
    if (!this._attachmentBind) return;
    const { container, handler } = this._attachmentBind;
    container.removeEventListener("click", handler);
    this._attachmentBind = null;
  },

  _teardownAttachment() {
    this._unbindAttachmentEvents();
    this._attachmentMode = false;
  },

  /**
   * Handle click to place a file attachment pin, then trigger file upload.
   */
  _onAttachmentClick(e) {
    if (!this._attachmentMode) return;
    e.preventDefault();

    const pos = this._shapePointerPos(e);
    const pageIndex = pos.pageIndex;

    // Render pin icon at click location.
    this._clearCustomSvg();
    if (!this._customSvg) return;

    const ns = "http://www.w3.org/2000/svg";
    const pinSize = 20;

    const pin = document.createElementNS(ns, "g");
    pin.setAttribute("transform", `translate(${pos.x - pinSize / 2}, ${pos.y - pinSize})`);

    // Pin circle
    const circle = document.createElementNS(ns, "circle");
    circle.setAttribute("cx", pinSize / 2);
    circle.setAttribute("cy", pinSize / 2);
    circle.setAttribute("r", pinSize / 2);
    circle.setAttribute("fill", "#dc2626");
    circle.setAttribute("stroke", "#fff");
    circle.setAttribute("stroke-width", "1.5");
    pin.appendChild(circle);

    // Pin inner dot
    const dot = document.createElementNS(ns, "circle");
    dot.setAttribute("cx", pinSize / 2);
    dot.setAttribute("cy", pinSize / 2);
    dot.setAttribute("r", 3);
    dot.setAttribute("fill", "#fff");
    pin.appendChild(dot);

    this._customSvg.appendChild(pin);

    // Create a hidden file input and trigger upload.
    const fileInput = document.createElement("input");
    fileInput.type = "file";
    fileInput.style.display = "none";
    document.body.appendChild(fileInput);

    fileInput.addEventListener("change", () => {
      const file = fileInput.files && fileInput.files[0];
      if (!file) {
        this._clearCustomSvg();
        document.body.removeChild(fileInput);
        return;
      }

      // Read file bytes.
      const reader = new FileReader();
      reader.onload = () => {
        const bytes = reader.result;
        // Remove base64 prefix if present
        const base64Data = typeof bytes === "string" && bytes.includes(",")
          ? bytes.split(",")[1]
          : bytes;

        const pageViews = this._buildPageViews();
        const data = {
          id: `attachment_${Date.now()}`,
          pageIndex,
          rect: [pos.x - 10, pos.y - 10, 20, 20],
          fileName: file.name,
          fileSize: file.size,
          fileType: file.type,
          fileData: base64Data,
        };
        const converted = this._convertCoordinates(data.id, data, pageViews);
        data.rectPdf = converted.rectPdf;

        this.pushEvent("annot_committed", { type: "file_attachment", data });
        this._clearCustomSvg();
        document.body.removeChild(fileInput);
      };
      reader.onerror = () => {
        this._clearCustomSvg();
        document.body.removeChild(fileInput);
      };
      reader.readAsDataURL(file);
    });

    fileInput.click();
  },

  /* ── free-text callout mode (T-107) ───────────────────────────────── */

  /**
   * Activate free-text callout mode. Mousedown places the leader line
   * anchor point, drag sets the text box size, then text entry begins.
   */
  _activateCalloutMode() {
    if (this._calloutMode === "free_text_callout") {
      this._deactivateCalloutMode();
      return;
    }

    try {
      this._viewer.annotationEditorMode = { mode: TYPE_NONE };
    } catch (_) { /* ignore */ }

    this._calloutMode = "free_text_callout";
    this._calloutState = "idle";
    this._ensureCustomSvg();
    this._bindCalloutEvents();

    this.pushEvent("annot_mode_changed", { mode: 0 });
  },

  _deactivateCalloutMode() {
    this._cancelCallout();
    this._unbindCalloutEvents();
    this._calloutMode = null;
  },

  _cancelCallout() {
    this._clearCustomSvg();
    this._removeCalloutTextDiv();
    this._calloutState = "idle";
    this._calloutAnchor = null;
    this._calloutRect = null;
    this._calloutPageIndex = null;
  },

  _removeCalloutTextDiv() {
    if (this._calloutTextDiv && this._calloutTextDiv.parentNode) {
      this._calloutTextDiv.parentNode.removeChild(this._calloutTextDiv);
    }
    this._calloutTextDiv = null;
  },

  _bindCalloutEvents() {
    this._unbindCalloutEvents();

    const container = this.el.querySelector("#pdf-viewer-container") ||
                      this.el;

    const handlers = {
      mousedown: (e) => this._onCalloutPointerDown(e),
      mousemove: (e) => this._onCalloutPointerMove(e),
      mouseup: (e) => this._onCalloutPointerUp(e),
      touchstart: (e) => this._onCalloutTouchStart(e),
      touchmove: (e) => this._onCalloutTouchMove(e),
      touchend: (e) => this._onCalloutTouchEnd(e),
    };

    for (const [event, handler] of Object.entries(handlers)) {
      container.addEventListener(event, handler, { passive: false });
    }

    this._calloutBind = { container, handlers };
  },

  _unbindCalloutEvents() {
    if (!this._calloutBind) return;
    const { container, handlers } = this._calloutBind;
    for (const [event, handler] of Object.entries(handlers)) {
      container.removeEventListener(event, handler);
    }
    this._calloutBind = null;
  },

  _teardownCallout() {
    this._unbindCalloutEvents();
    this._cancelCallout();
    this._calloutMode = null;
  },

  _onCalloutPointerDown(e) {
    if (!this._calloutMode) return;
    e.preventDefault();

    const pos = this._shapePointerPos(e);
    this._calloutPageIndex = pos.pageIndex;
    this._calloutAnchor = { x: pos.x, y: pos.y };
    this._calloutRect = { x: pos.x, y: pos.y, w: 0, h: 0 };
    this._calloutState = "sizing";
  },

  _onCalloutPointerMove(e) {
    if (this._calloutState !== "sizing") return;
    if (!this._calloutAnchor || !this._calloutRect) return;
    e.preventDefault();

    const pos = this._shapePointerPos(e);
    const x = Math.min(this._calloutAnchor.x, pos.x);
    const y = Math.min(this._calloutAnchor.y, pos.y);
    const w = Math.abs(pos.x - this._calloutAnchor.x);
    const h = Math.abs(pos.y - this._calloutAnchor.y);

    this._calloutRect = { x, y, w, h };
    this._renderCalloutPreview();
  },

  _onCalloutPointerUp(e) {
    if (this._calloutState !== "sizing") return;
    if (!this._calloutAnchor || !this._calloutRect) return;
    e.preventDefault();

    // Minimum size check.
    if (this._calloutRect.w < 30 || this._calloutRect.h < 20) {
      this._cancelCallout();
      return;
    }

    this._calloutState = "editing";
    this._renderCalloutFinal();
    this._showCalloutTextInput();
  },

  _onCalloutTouchStart(e) {
    if (!this._calloutMode) return;
    e.preventDefault();
    const touch = e.touches[0];
    if (!touch) return;
    this._onCalloutPointerDown(touch);
  },

  _onCalloutTouchMove(e) {
    if (this._calloutState !== "sizing") return;
    e.preventDefault();
    const touch = e.touches[0];
    if (!touch) return;
    this._onCalloutPointerMove(touch);
  },

  _onCalloutTouchEnd(e) {
    if (this._calloutState !== "sizing") return;
    e.preventDefault();
    this._onCalloutPointerUp(e);
  },

  /** Render the callout preview during sizing (leader line + text box outline). */
  _renderCalloutPreview() {
    this._clearCustomSvg();
    if (!this._customSvg || !this._calloutAnchor || !this._calloutRect) return;

    const svg = this._customSvg;
    const ns = "http://www.w3.org/2000/svg";
    const rect = this._calloutRect;
    const anchor = this._calloutAnchor;
    const color = this._calloutColor;

    // Leader line: from text box top-left to anchor point
    const leaderX = rect.x;
    const leaderY = rect.y;

    const leader = document.createElementNS(ns, "line");
    leader.setAttribute("x1", leaderX);
    leader.setAttribute("y1", leaderY);
    leader.setAttribute("x2", anchor.x);
    leader.setAttribute("y2", anchor.y);
    leader.setAttribute("stroke", color);
    leader.setAttribute("stroke-width", "1.5");
    leader.setAttribute("stroke-dasharray", "4,2");
    svg.appendChild(leader);

    // Anchor dot (circle at the leader line endpoint)
    const dot = document.createElementNS(ns, "circle");
    dot.setAttribute("cx", anchor.x);
    dot.setAttribute("cy", anchor.y);
    dot.setAttribute("r", 3);
    dot.setAttribute("fill", color);
    svg.appendChild(dot);

    // Text box outline
    const box = document.createElementNS(ns, "rect");
    box.setAttribute("x", rect.x);
    box.setAttribute("y", rect.y);
    box.setAttribute("width", rect.w);
    box.setAttribute("height", rect.h);
    box.setAttribute("fill", "rgba(255,255,255,0.9)");
    box.setAttribute("stroke", color);
    box.setAttribute("stroke-width", "1");
    box.setAttribute("rx", "2");
    svg.appendChild(box);
  },

  /** Render the final callout without dashed preview lines. */
  _renderCalloutFinal() {
    this._clearCustomSvg();
    if (!this._customSvg || !this._calloutAnchor || !this._calloutRect) return;

    const svg = this._customSvg;
    const ns = "http://www.w3.org/2000/svg";
    const rect = this._calloutRect;
    const anchor = this._calloutAnchor;
    const color = this._calloutColor;

    // Leader line (solid)
    const leaderX = rect.x;
    const leaderY = rect.y;

    const leader = document.createElementNS(ns, "line");
    leader.setAttribute("x1", leaderX);
    leader.setAttribute("y1", leaderY);
    leader.setAttribute("x2", anchor.x);
    leader.setAttribute("y2", anchor.y);
    leader.setAttribute("stroke", color);
    leader.setAttribute("stroke-width", "1.5");
    svg.appendChild(leader);

    // Anchor dot
    const dot = document.createElementNS(ns, "circle");
    dot.setAttribute("cx", anchor.x);
    dot.setAttribute("cy", anchor.y);
    dot.setAttribute("r", 3);
    dot.setAttribute("fill", color);
    svg.appendChild(dot);

    // Text box (white fill, colored border)
    const box = document.createElementNS(ns, "rect");
    box.setAttribute("x", rect.x);
    box.setAttribute("y", rect.y);
    box.setAttribute("width", rect.w);
    box.setAttribute("height", rect.h);
    box.setAttribute("fill", "rgba(255,255,255,0.95)");
    box.setAttribute("stroke", color);
    box.setAttribute("stroke-width", "1");
    box.setAttribute("rx", "2");
    svg.appendChild(box);
  },

  /** Show a contenteditable div for text entry in the callout text box. */
  _showCalloutTextInput() {
    this._removeCalloutTextDiv();
    if (!this._calloutRect) return;

    const container = this.el.querySelector("#pdf-viewer-container") ||
                      this.el;
    const rect = this._calloutRect;
    const containerRect = container.getBoundingClientRect();

    const div = document.createElement("div");
    div.contentEditable = "true";
    div.style.cssText = `
      position: absolute;
      left: ${rect.x}px;
      top: ${rect.y}px;
      width: ${rect.w}px;
      height: ${rect.h}px;
      font-size: ${this._calloutFontSize}px;
      color: ${this._calloutColor};
      background: transparent;
      border: none;
      outline: none;
      padding: 4px 6px;
      box-sizing: border-box;
      overflow: hidden;
      word-wrap: break-word;
      font-family: Arial, sans-serif;
      line-height: 1.3;
      z-index: 20;
      cursor: text;
    `;
    div.textContent = "Type here…";

    // Handle Enter to commit.
    div.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        this._commitCallout(div.textContent);
      }
      if (e.key === "Escape") {
        e.preventDefault();
        this._cancelCallout();
      }
    });

    // Handle blur to commit.
    div.addEventListener("blur", () => {
      this._commitCallout(div.textContent);
    });

    // Focus after adding to DOM.
    container.style.position = "relative";
    container.appendChild(div);
    this._calloutTextDiv = div;
    setTimeout(() => div.focus(), 50);
  },

  /** Commit the free-text callout annotation. */
  _commitCallout(text) {
    if (!this._calloutAnchor || !this._calloutRect) {
      this._cancelCallout();
      return;
    }

    const content = (text && text.trim() !== "Type here…") ? text.trim() : "";

    const pageViews = this._buildPageViews();
    const rect = [
      this._calloutRect.x,
      this._calloutRect.y,
      this._calloutRect.x + this._calloutRect.w,
      this._calloutRect.y + this._calloutRect.h,
    ];

    const data = {
      id: `callout_${Date.now()}`,
      pageIndex: this._calloutPageIndex || 0,
      rect,
      content,
      anchor: [this._calloutAnchor.x, this._calloutAnchor.y],
      color: this._calloutColor,
      fontSize: this._calloutFontSize,
    };

    const converted = this._convertCoordinates(data.id, data, pageViews);
    data.rectPdf = converted.rectPdf;
    if (data.anchor) {
      const pt = converted.rectPdf
        ? null
        : pageViews.get(data.pageIndex)?.viewport?.convertToPdfPoint(data.anchor[0], data.anchor[1]);
      if (pt) data.anchorPdf = [pt[0], pt[1]];
    }

    this.pushEvent("annot_committed", { type: "free_text_callout", data });

    this._removeCalloutTextDiv();
    this._clearCustomSvg();
    this._calloutState = "idle";
  },

  /* ── custom SVG helpers (T-107) ───────────────────────────────────── */

  /** Ensure the shared custom SVG overlay exists. */
  _ensureCustomSvg() {
    if (this._customSvg && this._customSvg.parentNode) return;

    const wrapper = this.el.querySelector("#pdf-viewer-container") ||
                    this.el.querySelector("#pdf-viewer-container-left") ||
                    this.el;

    if (!wrapper) return;

    const old = wrapper.querySelector(".custom-overlay-svg");
    if (old) old.remove();

    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "custom-overlay-svg");
    svg.style.cssText = "position:absolute;top:0;left:0;width:100%;height:100%;overflow:visible;z-index:11;pointer-events:none;";
    wrapper.appendChild(svg);
    this._customSvg = svg;
  },

  _clearCustomSvg() {
    if (!this._customSvg) return;
    while (this._customSvg.firstChild) {
      this._customSvg.removeChild(this._customSvg.firstChild);
    }
  },

  _cleanupCustomSvg() {
    if (this._customSvg && this._customSvg.parentNode) {
      this._customSvg.parentNode.removeChild(this._customSvg);
    }
    this._customSvg = null;
  },

  /* ── ink config ───────────────────────────────────────────────────── */

  /**
   * Apply an ink editor parameter change via the event bus.
   * The AnnotationEditorUIManager listens for "switchannotationeditorparams"
   * and updates the current and future ink editors accordingly.
   */
  _applyInkConfig(type, value) {
    if (!this._viewer || !this._eventBus) return;

    try {
      this._eventBus.dispatch("switchannotationeditorparams", {
        source: this,
        type,
        value,
      });
    } catch (err) {
      console.warn("AnnotEditHook: failed to apply ink config:", err);
    }
  },

  /* ── serialisation ───────────────────────────────────────────────── */

  /**
   * Serialise all committed editors from annotationStorage and push
   * each one as an annot_committed event (or annot_deleted for deletions).
   *
   * Coordinates are converted via PageViewport.convertToPdfPoint to
   * yield PDF points per §14.3 of ISO 32000-2.
   */
  _captureCommitted() {
    const pdfDoc = this._viewer && this._viewer.pdfDocument;
    if (!pdfDoc) return;

    try {
      const storage = pdfDoc.annotationStorage;
      if (!storage || !storage.serializable) return;

      const { map } = storage.serializable;
      if (!map || map.size === 0) return;

      // Build a lookup from page index to PDFPageView for
      // viewport coordinate conversion.
      /** @type {Map<number, object>} */
      const pageViews = this._buildPageViews();

      for (const [id, editorData] of map) {
        // Handle deleted editors (eraser or undo)
        if (editorData.deleted) {
          this.pushEvent("annot_deleted", {
            id,
            type: this._editorTypeName(editorData.annotationType, editorData) || "unknown",
            pageIndex: editorData.pageIndex,
          });
          continue;
        }

        const type = this._editorTypeName(editorData.annotationType, editorData);
        if (!type) continue; // skip unknown types

        // Convert CSS coordinates to PDF points if we have a page view
        const data = this._convertCoordinates(id, editorData, pageViews);

        // For sticky-note (comment) annotations, attach the currently
        // selected icon name and colour so the server can persist them.
        if (editorData.annotationType === 102) {
          data.icon = this._stickyIcon;
          data.color = this._stickyColor;
        }

        // For ink annotations, ensure path data is preserved.
        // pdf.js InkEditor.serialize() already produces paths, color,
        // thickness, and opacity in the data payload.
        this.pushEvent("annot_committed", { type, data });
      }
    } catch (e) {
      // Editors are also captured via saveDocument() — silence client errors
    }
  },

  /**
   * Return a human-readable name for an AnnotationEditorType constant.
   * Text-markup subtypes (highlight/underline/strikethrough/squiggly)
   * share type 9; the actual subtype is embedded in the serialized data.
   *
   * @param {number} annotationType
   * @param {object} [data] - Optional serialized editor data for subtype resolution
   * @returns {string|null}
   */
  _editorTypeName(annotationType, data) {
    const names = {
      3: "freeText",
      9: "highlight",
      15: "ink",
      13: "stamp",
      101: "signature",
      102: "comment",
    };

    // Text-markup annotations (type 9) store the actual subtype in the
    // serialized data (highlight, underline, strikeout, squiggly).
    if (annotationType === 9 && data && data.subtype) {
      return data.subtype;
    }

    return names[annotationType] || null;
  },

  /**
   * Convert editor bounding rect from CSS pixels to PDF points using
   * the page viewport.
   *
   * @param {string} id - Editor id
   * @param {object} editorData - raw serialized data from annotationStorage
   * @param {Map<number,object>} pageViews - map of pageIndex -> PDFPageView
   * @returns {object} enriched data with pdf coordinates
   */
  _convertCoordinates(id, editorData, pageViews) {
    const data = { id, ...editorData };

    const pageIndex = data.pageIndex;
    if (pageIndex == null) return data;

    const pageView = pageViews.get(pageIndex);
    if (!pageView || !pageView.viewport) return data;

    const vp = pageView.viewport;

    // The serialized editor data may contain a `rect` (bounding box in
    // CSS pixels) or just position properties.  Convert whatever we find.
    if (data.rect && Array.isArray(data.rect) && data.rect.length === 4) {
      const [cssX1, cssY1, cssX2, cssY2] = data.rect;

      const pt1 = vp.convertToPdfPoint(cssX1, cssY1);
      const pt2 = vp.convertToPdfPoint(cssX2, cssY2);

      data.rectPdf = [
        Math.min(pt1[0], pt2[0]),
        Math.min(pt1[1], pt2[1]),
        Math.max(pt1[0], pt2[0]),
        Math.max(pt1[1], pt2[1]),
      ];
    }

    // Convert individual position if present
    if (data.x != null && data.y != null) {
      const pt = vp.convertToPdfPoint(data.x, data.y);
      data.xPdf = pt[0];
      data.yPdf = pt[1];
    }

    // Convert quadPoints (text-markup annotations) to PDF coordinates.
    // Each quad is an array of 4 {x,y} point objects in CSS pixel space.
    if (data.quadPoints && Array.isArray(data.quadPoints)) {
      data.quadPointsPdf = data.quadPoints.map((quad) => {
        if (Array.isArray(quad)) {
          // Flat array: [x1,y1,x2,y2,x3,y3,x4,y4]
          const pts = [];
          for (let i = 0; i < quad.length; i += 2) {
            const p = vp.convertToPdfPoint(quad[i], quad[i + 1]);
            pts.push(p[0], p[1]);
          }
          return pts;
        }
        // Object array: [{x,y},{x,y},{x,y},{x,y}]
        return quad.map((p) => {
          const pt = vp.convertToPdfPoint(p.x, p.y);
          return [pt[0], pt[1]];
        }).flat();
      });
    }

    return data;
  },
};

export default AnnotEditHook;
