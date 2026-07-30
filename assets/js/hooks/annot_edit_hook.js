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
  },

  destroyed() {
    this._cleanupEraser();
    this._teardownShape();
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

    // Handle shape modes separately from pdf.js native modes.
    if (SHAPE_MODES.has(modeStr)) {
      this._activateShapeMode(modeStr);
      return;
    }

    // Non-shape modes: use pdf.js annotation editor.
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
      case "dimension": {
        this._renderLineShape(svg, ns);
        break;
      }
      case "oval": {
        this._renderOvalShape(svg, ns);
        break;
      }
      case "rectangle": {
        this._renderRectShape(svg, ns);
        break;
      }
      case "polygon":
      case "cloud":
      case "polyline": {
        this._renderVertexShape(svg, ns);
        break;
      }
    }
  },

  /** Render a line/arrow based shape (line, arrow, double_arrow, dimension). */
  _renderLineShape(svg, ns) {
    const s = this._shapeStart;
    const c = this._shapeCurrent || s;
    if (!s || !c) return;
    const strokeW = this._strokeWidth;
    const color = this._strokeColor;
    const opacity = this._shapeOpacity;

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

    const rect = document.createElementNS(ns, "rect");
    rect.setAttribute("x", x);
    rect.setAttribute("y", y);
    rect.setAttribute("width", Math.max(w, 1));
    rect.setAttribute("height", Math.max(h, 1));
    rect.setAttribute("fill", this._fillColor);
    rect.setAttribute("fill-opacity", this._shapeOpacity * 0.3);
    rect.setAttribute("stroke", this._strokeColor);
    rect.setAttribute("stroke-width", this._strokeWidth);
    rect.setAttribute("stroke-opacity", this._shapeOpacity);
    svg.appendChild(rect);
  },

  /** Render a polygon/cloud/polyline vertex-based preview. */
  _renderVertexShape(svg, ns) {
    const verts = this._shapeVertices;
    if (verts.length === 0) return;

    const isClosed = this._shapeMode === "polygon" || this._shapeMode === "cloud";
    const isPolyline = this._shapeMode === "polyline";

    // Draw connecting lines
    if (verts.length >= 2) {
      // Draw all segments
      const pointsStr = verts.map(v => `${v.x},${v.y}`).join(" ");

      if (isClosed && verts.length >= 3) {
        // Closed shape: polygon or cloud
        const poly = document.createElementNS(ns, "polygon");
        poly.setAttribute("points", pointsStr);
        poly.setAttribute("fill", this._fillColor);
        poly.setAttribute("fill-opacity", this._shapeOpacity * 0.3);
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
      case "polyline": {
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

    if (mode === "line" || mode === "arrow" || mode === "double_arrow" || mode === "dimension") {
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

    if (mode === "polygon" || mode === "cloud" || mode === "polyline") {
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
