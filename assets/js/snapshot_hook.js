// SnapshotHook — T-055
//
// Colocated LiveView hook that adds marquee selection to the document
// canvas. When active (toggled by the snapshot toolbar button), the
// user drags a rectangle on the canvas. On release the visible PDF
// canvas region is captured at 2x resolution and the resulting data URL
// is pushed to the server (clipboard) and offered as a download.

const SnapshotHook = {
  mounted() {
    // ── State ─────────────────────────────────────────────────────────────
    this.active = false;
    this.startX = 0;
    this.startY = 0;
    this.rectEl = null;
    this._onMouseDown = null;
    this._onMouseMove = null;
    this._onMouseUp = null;

    // ── Server toggles ────────────────────────────────────────────────────

    this.handleEvent("toggle_snapshot", ({ active }) => {
      this.active = active;
      this.el.style.cursor = this.active ? "crosshair" : "";
      this._removeOverlay();
      if (this.active) {
        this._bindDrag();
      } else {
        this._unbindDrag();
      }
    });

    // ── Keyboard: Esc deactivates snapshot mode ───────────────────────────

    this._onKeyDown = (e) => {
      if (e.key === "Escape" && this.active) {
        this.active = false;
        this.el.style.cursor = "";
        this._removeOverlay();
        this._unbindDrag();
        this.pushEvent("toggle_snapshot_mode", {});
      }
    };
    document.addEventListener("keydown", this._onKeyDown);
  },

  destroyed() {
    this._unbindDrag();
    this._removeOverlay();
    if (this._onKeyDown) {
      document.removeEventListener("keydown", this._onKeyDown);
    }
  },

  // ── Drag binding ────────────────────────────────────────────────────────

  _bindDrag() {
    this._onMouseDown = (e) => {
      if (!this.active) return;
      // Ignore right-click
      if (e.button !== 0) return;
      e.preventDefault();

      const rect = this.el.getBoundingClientRect();
      this.startX = e.clientX - rect.left;
      this.startY = e.clientY - rect.top;

      this._drawOverlay(this.startX, this.startY, this.startX, this.startY);

      this._onMouseMove = (ev) => {
        ev.preventDefault();
        const cx = ev.clientX - rect.left;
        const cy = ev.clientY - rect.top;
        this._drawOverlay(this.startX, this.startY, cx, cy);
      };

      this._onMouseUp = (ev) => {
        ev.preventDefault();
        this._unbindDrag();

        const endX = ev.clientX - rect.left;
        const endY = ev.clientY - rect.top;

        const x = Math.min(this.startX, endX);
        const y = Math.min(this.startY, endY);
        const w = Math.abs(endX - this.startX);
        const h = Math.abs(endY - this.startY);

        // Ignore clicks / tiny selections
        if (w < 4 || h < 4) {
          this._removeOverlay();
          return;
        }

        this._capture(x, y, w, h);
      };

      document.addEventListener("mousemove", this._onMouseMove);
      document.addEventListener("mouseup", this._onMouseUp);
    };

    this.el.addEventListener("mousedown", this._onMouseDown);
  },

  _unbindDrag() {
    if (this._onMouseDown) {
      this.el.removeEventListener("mousedown", this._onMouseDown);
      this._onMouseDown = null;
    }
    if (this._onMouseMove) {
      document.removeEventListener("mousemove", this._onMouseMove);
      this._onMouseMove = null;
    }
    if (this._onMouseUp) {
      document.removeEventListener("mouseup", this._onMouseUp);
      this._onMouseUp = null;
    }
  },

  // ── Overlay ─────────────────────────────────────────────────────────────

  _drawOverlay(x1, y1, x2, y2) {
    if (!this.rectEl) {
      this.rectEl = document.createElement("div");
      this.rectEl.className =
        "snapshot-marquee";
      Object.assign(this.rectEl.style, {
        position: "absolute",
        border: "2px solid #3b82f6",
        background: "rgba(59, 130, 246, 0.12)",
        pointerEvents: "none",
        zIndex: "1000",
        borderRadius: "2px",
      });
      this.el.appendChild(this.rectEl);
    }

    const x = Math.min(x1, x2);
    const y = Math.min(y1, y2);
    const w = Math.abs(x2 - x1);
    const h = Math.abs(y2 - y1);

    this.rectEl.style.left = `${x}px`;
    this.rectEl.style.top = `${y}px`;
    this.rectEl.style.width = `${w}px`;
    this.rectEl.style.height = `${h}px`;
  },

  _removeOverlay() {
    if (this.rectEl && this.rectEl.parentNode) {
      this.rectEl.parentNode.removeChild(this.rectEl);
    }
    this.rectEl = null;
  },

  // ── Capture ─────────────────────────────────────────────────────────────

  _capture(x, y, w, h) {
    // Find the pdf.js canvas(es) inside the viewer container.
    // We capture from the first (or only) visible page canvas.
    const container = this.el.querySelector("#pdf-viewer-container");
    if (!container) return;

    const canvas = container.querySelector("canvas");
    if (!canvas) return;

    // Compute the scale ratio between the canvas natural size and its
    // CSS-displayed size so we can sample at 2x device-pixel resolution.
    const cssRect = canvas.getBoundingClientRect();
    const scaleX = canvas.width / cssRect.width;
    const scaleY = canvas.height / cssRect.height;

    // The marquee is in the document-canvas coordinate space. If the
    // canvas is scrolled or offset within the container, adjust.
    const canvasOffsetX = cssRect.left - this.el.getBoundingClientRect().left;
    const canvasOffsetY = cssRect.top - this.el.getBoundingClientRect().top;

    // Intersect the marquee with the canvas area
    const relX = Math.max(0, x - canvasOffsetX);
    const relY = Math.max(0, y - canvasOffsetY);
    const relW = Math.min(w, cssRect.width - relX);
    const relH = Math.min(h, cssRect.height - relY);

    if (relW < 2 || relH < 2) {
      this._removeOverlay();
      return;
    }

    // Offscreen canvas at 2x
    const outCanvas = document.createElement("canvas");
    outCanvas.width = relW * scaleX * 2;
    outCanvas.height = relH * scaleY * 2;

    const ctx = outCanvas.getContext("2d");
    // Disable image smoothing for sharp pixel capture
    ctx.imageSmoothingEnabled = false;

    ctx.drawImage(
      canvas,
      relX * scaleX, relY * scaleY,
      relW * scaleX, relH * scaleY,
      0, 0,
      outCanvas.width, outCanvas.height
    );

    this._removeOverlay();

    // Push data URL to server
    const dataUrl = outCanvas.toDataURL("image/png");
    this.pushEvent("snapshot_captured", { dataUrl });

    // Offer download
    const link = document.createElement("a");
    link.download = `snapshot-${Date.now()}.png`;
    link.href = dataUrl;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  },
};

export default SnapshotHook;
