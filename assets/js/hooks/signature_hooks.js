// Signature capture hooks (plan3.md §9.4, T-114)
//
// Three colocated hooks for draw, type, and upload signature capture.
// Each hook manages its own DOM interactions and pushes completed
// signature data to the server via pushEvent.
//
// Draw: pointer-events canvas with pressure-aware smoothing
// Type: font-aware text rendering → contour extraction
// Upload: canvas-based background removal (threshold to alpha)

// ── Drawing helpers ──────────────────────────────────────────────────────────

/** Douglas-Peucker simplification with a distance threshold. */
function simplify(points, epsilon = 1.0) {
  if (points.length <= 2) return points;

  let maxDist = 0;
  let maxIdx = 0;
  const first = points[0];
  const last = points[points.length - 1];

  for (let i = 1; i < points.length - 1; i++) {
    const d = perpendicularDist(points[i], first, last);
    if (d > maxDist) {
      maxDist = d;
      maxIdx = i;
    }
  }

  if (maxDist > epsilon) {
    const left = simplify(points.slice(0, maxIdx + 1), epsilon);
    const right = simplify(points.slice(maxIdx), epsilon);
    return left.slice(0, -1).concat(right);
  }

  return [first, last];
}

function perpendicularDist(p, a, b) {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const len = Math.sqrt(dx * dx + dy * dy);
  if (len === 0) return Math.sqrt((p.x - a.x) ** 2 + (p.y - a.y) ** 2);
  return Math.abs(dy * (p.x - a.x) - dx * (p.y - a.y)) / len;
}

/** Catmull-Rom → polyline smoothing with tension 0.5. */
function smoothCatmullRom(points, segments = 8) {
  if (points.length < 3) return points;

  const result = [points[0]];
  for (let i = 1; i < points.length - 1; i++) {
    const p0 = points[i - 1];
    const p1 = points[i];
    const p2 = points[i + 1];
    const p3 = points[Math.min(i + 2, points.length - 1)];

    for (let t = 0; t < segments; t++) {
      const s = t / segments;
      const s2 = s * s;
      const s3 = s2 * s;

      const x = 0.5 * (
        (2 * p1.x) +
        (-p0.x + p2.x) * s +
        (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * s2 +
        (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * s3
      );
      const y = 0.5 * (
        (2 * p1.y) +
        (-p0.y + p2.y) * s +
        (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * s2 +
        (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * s3
      );
      result.push({ x, y });
    }
  }
  result.push(points[points.length - 1]);
  return result;
}

/** Normalise pointer event, extracting coordinates and pressure. */
function pointerPos(canvas, e) {
  const rect = canvas.getBoundingClientRect();
  const x = (e.clientX - rect.left) / rect.width;
  const y = (e.clientY - rect.top) / rect.height;
  const pressure = e.pressure !== undefined && e.pressure > 0 ? e.pressure : 0.5;
  return { x, y, pressure: Math.min(1, pressure) };
}

// ── Draw hook — canvas signature capture ─────────────────────────────────────

const SignatureDraw = {
  mounted() {
    this._canvas = this.el.querySelector("#sig-draw-canvas");
    this._ctx = this._canvas.getContext("2d");
    this._strokes = [];
    this._currentStroke = [];
    this._isDrawing = false;

    this._handlePointerDown = this._onPointerDown.bind(this);
    this._handlePointerMove = this._onPointerMove.bind(this);
    this._handlePointerUp = this._onPointerUp.bind(this);

    this._resizeCanvas();
    this._canvas.addEventListener("pointerdown", this._handlePointerDown);
    this._canvas.addEventListener("pointermove", this._handlePointerMove);
    this._canvas.addEventListener("pointerup", this._handlePointerUp);
    this._canvas.addEventListener("pointerleave", this._handlePointerUp);

    // Re-observe element for resize
    this._resizeObserver = new ResizeObserver(() => this._resizeCanvas());
    this._resizeObserver.observe(this.el);

    // Expose instance on the container so sibling hooks can reach it
    this.el._signatureDraw = this;
  },

  destroyed() {
    this._canvas.removeEventListener("pointerdown", this._handlePointerDown);
    this._canvas.removeEventListener("pointermove", this._handlePointerMove);
    this._canvas.removeEventListener("pointerup", this._handlePointerUp);
    this._canvas.removeEventListener("pointerleave", this._handlePointerUp);
    this._resizeObserver?.disconnect();
    delete this.el._signatureDraw;
  },

  _resizeCanvas() {
    const rect = this.el.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    this._canvas.width = rect.width * dpr;
    this._canvas.height = rect.height * dpr;
    this._ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this._canvas.style.width = rect.width + "px";
    this._canvas.style.height = rect.height + "px";
    this._ctx.strokeStyle = "#000";
    this._ctx.lineWidth = 2.5;
    this._ctx.lineCap = "round";
    this._ctx.lineJoin = "round";
    this._redraw();
  },

  _onPointerDown(e) {
    e.preventDefault();
    this._canvas.setPointerCapture(e.pointerId);
    this._isDrawing = true;
    const pos = pointerPos(this._canvas, e);
    this._currentStroke = [{ ...pos, time: Date.now() }];
    this._hidePlaceholder();
  },

  _onPointerMove(e) {
    if (!this._isDrawing) return;
    e.preventDefault();
    const pos = pointerPos(this._canvas, e);
    // Interpolate missing points for fast moves
    const last = this._currentStroke[this._currentStroke.length - 1];
    const dx = pos.x - last.x;
    const dy = pos.y - last.y;
    const dist = Math.sqrt(dx * dx + dy * dy);
    if (dist > 0.02) {
      // Draw a dot at the current position for real-time feedback
      this._drawDot(pos);
    }
    this._currentStroke.push({ ...pos, time: Date.now() });
  },

  _onPointerUp(e) {
    if (!this._isDrawing) return;
    this._isDrawing = false;

    if (this._currentStroke.length > 2) {
      // Smooth the stroke
      const smoothed = smoothCatmullRom(this._currentStroke, 6);
      const thinned = simplify(smoothed, 0.5);
      this._strokes.push(thinned);
    }

    this._currentStroke = [];
    this._redraw();
    this._showPlaceholderIfEmpty();
  },

  _drawDot(pos) {
    const canvas = this._canvas;
    const ctx = this._ctx;
    const w = canvas.getBoundingClientRect().width;
    const h = canvas.getBoundingClientRect().height;
    const x = pos.x * w;
    const y = pos.y * h;
    const radius = Math.max(1, 2.5 * pos.pressure);

    ctx.beginPath();
    ctx.arc(x, y, radius, 0, Math.PI * 2);
    ctx.fillStyle = "#000";
    ctx.fill();
  },

  _redraw() {
    const ctx = this._ctx;
    const w = this._canvas.getBoundingClientRect().width;
    const h = this._canvas.getBoundingClientRect().height;

    ctx.clearRect(0, 0, w, h);
    ctx.strokeStyle = "#000";
    ctx.lineWidth = 2.5;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";

    for (const stroke of this._strokes) {
      if (stroke.length < 2) continue;
      ctx.beginPath();
      ctx.moveTo(stroke[0].x * w, stroke[0].y * h);
      for (let i = 1; i < stroke.length; i++) {
        ctx.lineTo(stroke[i].x * w, stroke[i].y * h);
      }
      ctx.stroke();
    }
  },

  _hidePlaceholder() {
    const ph = document.getElementById("sig-draw-placeholder");
    if (ph) ph.classList.add("hidden");
  },

  _showPlaceholderIfEmpty() {
    if (this._strokes.length > 0) return;
    const ph = document.getElementById("sig-draw-placeholder");
    if (ph) ph.classList.remove("hidden");
  },

  /** Serialise strokes to a compact JSON payload for the server. */
  serialise() {
    const w = this._canvas.getBoundingClientRect().width;
    const h = this._canvas.getBoundingClientRect().height;
    return {
      strokes: this._strokes.map(stroke => stroke.map(p => ({
        x: p.x, y: p.y, pressure: p.pressure
      }))),
      width: w,
      height: h
    };
  },

  clear() {
    this._strokes = [];
    this._currentStroke = [];
    this._isDrawing = false;
    const ctx = this._ctx;
    const w = this._canvas.getBoundingClientRect().width;
    const h = this._canvas.getBoundingClientRect().height;
    ctx.clearRect(0, 0, w, h);
    this._showPlaceholderIfEmpty();
  }
};

// ── Draw Clear hook ──────────────────────────────────────────────────────────

const SignatureDrawClear = {
  mounted() {
    this.el.addEventListener("click", () => {
      const container = document.getElementById("sig-draw-canvas-container");
      if (container && container._signatureDraw) {
        container._signatureDraw.clear();
      }
    });
  }
};

// ── Draw Save hook ───────────────────────────────────────────────────────────

const SignatureDrawSave = {
  mounted() {
    this.el.addEventListener("click", () => {
      const container = document.getElementById("sig-draw-canvas-container");
      const labelInput = document.getElementById("sig-draw-label");
      if (!container || !container._signatureDraw) return;

      const data = container._signatureDraw.serialise();
      const label = labelInput ? labelInput.value.trim() || "Drawn Signature" : "Drawn Signature";

      this.pushEvent("save_signature", {
        type: "draw",
        label,
        data: JSON.stringify(data)
      });
    });
  }
};

// ── Type Save hook ───────────────────────────────────────────────────────────

const SignatureTypeSave = {
  mounted() {
    this.el.addEventListener("click", () => {
      const textInput = document.getElementById("sig-type-input");
      const fontSelect = document.getElementById("sig-type-font");
      const sizeInput = document.getElementById("sig-type-size");
      const labelInput = document.getElementById("sig-type-label");

      const text = textInput ? textInput.value.trim() : "";
      if (!text) return;

      const font = fontSelect ? fontSelect.value : "Alex Brush";
      const size = sizeInput ? parseInt(sizeInput.value, 10) : 48;
      const label = labelInput ? labelInput.value.trim() || text : text;

      this.pushEvent("save_signature", {
        type: "type",
        label,
        data: JSON.stringify({ text, font, size })
      });
    });
  }
};

// ── Upload helpers ───────────────────────────────────────────────────────────

/** Apply a simple background-removal threshold: pixels near white → alpha. */
function removeBackground(imageData, threshold = 240) {
  const pixels = imageData.data;
  for (let i = 0; i < pixels.length; i += 4) {
    const r = pixels[i];
    const g = pixels[i + 1];
    const b = pixels[i + 2];
    // If all channels are above threshold, make transparent
    if (r >= threshold && g >= threshold && b >= threshold) {
      pixels[i + 3] = 0; // alpha = 0
    }
  }
  return imageData;
}

// ── Upload Save hook ─────────────────────────────────────────────────────────

const SignatureUploadSave = {
  mounted() {
    this.el.addEventListener("click", () => {
      const preview = document.getElementById("sig-upload-preview");
      const labelInput = document.getElementById("sig-upload-label");

      if (!preview || !preview.dataset.pngBase64) return;

      const pngBase64 = preview.dataset.pngBase64;
      const label = labelInput ? labelInput.value.trim() || "Uploaded Signature" : "Uploaded Signature";

      this.pushEvent("save_signature", {
        type: "upload",
        label,
        data: JSON.stringify({
          image: pngBase64
        })
      });

      // Reset for next use
      delete preview.dataset.pngBase64;
    });
  }
};

// ── Upload select handler ────────────────────────────────────────────────────

/** Coordinates with the phx-change event; reads file, applies bg removal, shows preview. */
export function handleUploadSelect(file) {
  if (!file) return;

  const reader = new FileReader();
  reader.onload = (e) => {
    const img = new Image();
    img.onload = () => {
      // Draw onto a canvas, apply background removal, then update preview
      const canvas = document.createElement("canvas");
      canvas.width = img.width;
      canvas.height = img.height;
      const ctx = canvas.getContext("2d");
      ctx.drawImage(img, 0, 0);

      const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
      removeBackground(imageData, 240);
      ctx.putImageData(imageData, 0, 0);

      const dataUrl = canvas.toDataURL("image/png");
      const preview = document.getElementById("sig-upload-preview");
      if (preview) {
        preview.innerHTML = `<img src="${dataUrl}" class="max-w-full max-h-32 object-contain" alt="Upload preview" />`;
        preview.classList.remove("hidden");
      }
    };
    img.src = e.target.result;
  };
  reader.readAsDataURL(file);
}

// ── Hook registry ────────────────────────────────────────────────────────────

export {
  SignatureDraw,
  SignatureDrawClear,
  SignatureDrawSave,
  SignatureTypeSave,
  SignatureUploadSave,
};
