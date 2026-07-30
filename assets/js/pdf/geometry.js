// Quire coordinate geometry (§14.3)
// All spatial values stored in PDF points (1/72 inch).
// Convert at the boundary — never do the maths inline.

/**
 * Convert a CSS/canvas bounding rect to PDF user-space points.
 * @param {number} x_css — left edge in CSS px from the canvas
 * @param {number} y_css — top edge in CSS px from the canvas
 * @param {number} w — width in CSS px
 * @param {number} h — height in CSS px
 * @param {number} pageHeight — the CSS-rendered height of the page
 * @param {object} [viewport] — pdf.js PageViewport for rotation handling
 * @returns {{x: number, y: number, width: number, height: number}}
 */
export function cssToPdf(x_css, y_css, w, h, pageHeight, viewport) {
  if (viewport) {
    // Use pdf.js's viewport conversion which handles /Rotate
    const topLeft = viewport.convertToPdfPoint(x_css, y_css);
    const bottomRight = viewport.convertToPdfPoint(x_css + w, y_css + h);
    return {
      x: topLeft[0],
      y: bottomRight[1],  // bottom edge in PDF coords
      width: Math.abs(bottomRight[0] - topLeft[0]),
      height: Math.abs(bottomRight[1] - topLeft[1])
    };
  }

  // Without viewport: simple origin flip (no rotation handling)
  return {
    x: x_css,
    y: pageHeight - y_css - h,
    width: w,
    height: h
  };
}

/**
 * Convert PDF user-space rect to CSS px for rendering.
 * @param {number} x_pdf
 * @param {number} y_pdf
 * @param {number} w_pdf
 * @param {number} h_pdf
 * @param {number} pageHeight — CSS-rendered page height
 * @param {object} [viewport] — pdf.js PageViewport
 * @returns {{x: number, y: number, width: number, height: number}}
 */
export function pdfToCss(x_pdf, y_pdf, w_pdf, h_pdf, pageHeight, viewport) {
  if (viewport) {
    const topLeft = viewport.convertToViewportPoint(x_pdf, y_pdf);
    const bottomRight = viewport.convertToViewportPoint(x_pdf + w_pdf, y_pdf + h_pdf);
    return {
      x: Math.min(topLeft[0], bottomRight[0]),
      y: Math.min(topLeft[1], bottomRight[1]),
      width: Math.abs(bottomRight[0] - topLeft[0]),
      height: Math.abs(bottomRight[1] - topLeft[1])
    };
  }

  // Without viewport: simple origin flip
  return {
    x: x_pdf,
    y: pageHeight - y_pdf - h_pdf,
    width: w_pdf,
    height: h_pdf
  };
}

/**
 * Subtract CropBox origin from a point.
 * When CropBox has a non-zero origin, subtract it to get MediaBox-frame coords.
 * @param {number} x — point x in CropBox frame
 * @param {number} y — point y in CropBox frame
 * @param {{x:number, y:number}} cropOrigin — CropBox top-left
 * @returns {{x:number, y:number}}
 */
export function subtractCropOrigin(x, y, cropOrigin) {
  return { x: x + cropOrigin.x, y: y + cropOrigin.y };
}

/**
 * Add CropBox origin (inverse of subtract).
 */
export function addCropOrigin(x, y, cropOrigin) {
  return { x: x - cropOrigin.x, y: y - cropOrigin.y };
}
