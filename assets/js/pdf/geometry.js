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

/**
 * Apply page rotation to a point (x, y) on a page of dimensions (w, h).
 * Based on ISO 32000-2 /Rotate values: 0, 90, 180, 270.
 * @param {number} x
 * @param {number} y
 * @param {number} w — page width
 * @param {number} h — page height
 * @param {number} degrees — rotation in degrees (0, 90, 180, 270)
 * @returns {{x: number, y: number}}
 */
export function applyRotation(x, y, w, h, degrees) {
  // Normalise to 0-359 (handles negative values for inverse transforms)
  const d = ((degrees % 360) + 360) % 360;
  switch (d) {
    case 90:  return { x: y, y: w - x };
    case 180: return { x: w - x, y: h - y };
    case 270: return { x: h - y, y: x };
    default:  return { x, y };
  }
}

/**
 * Euclidean distance between two points.
 * @param {{x:number, y:number}} a
 * @param {{x:number, y:number}} b
 * @returns {number}
 */
export function distance(a, b) {
  return Math.sqrt((b.x - a.x) ** 2 + (b.y - a.y) ** 2);
}

/**
 * Perimeter of a closed polygon.
 * @param {Array<{x:number, y:number}>} vertices
 * @returns {number}
 */
export function perimeter(vertices) {
  if (vertices.length < 2) return 0.0;
  let total = 0;
  for (let i = 0; i < vertices.length; i++) {
    const a = vertices[i];
    const b = vertices[(i + 1) % vertices.length];
    total += distance(a, b);
  }
  return total;
}

/**
 * Area of a polygon via the shoelace formula.
 * @param {Array<{x:number, y:number}>} vertices
 * @returns {number}
 */
export function area(vertices) {
  if (vertices.length < 3) return 0.0;
  let sum = 0;
  for (let i = 0; i < vertices.length; i++) {
    const a = vertices[i];
    const b = vertices[(i + 1) % vertices.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return Math.abs(sum) / 2.0;
}

/**
 * Convert a measurement from one unit to another.
 * Supported units: 'points', 'inches', 'mm', 'cm', 'meters'.
 * @param {number} value
 * @param {string} fromUnit
 * @param {string} toUnit
 * @returns {number}
 */
export function scaleMeasurement(value, fromUnit, toUnit) {
  if (fromUnit === toUnit) return value;
  const points = toPoints(value, fromUnit);
  return fromPoints(points, toUnit);
}

const POINTS_PER_INCH = 72.0;
const MM_PER_INCH = 25.4;
const CM_PER_INCH = 2.54;
const METERS_PER_INCH = 0.0254;

function toPoints(value, unit) {
  switch (unit) {
    case 'points': return value;
    case 'inches': return value * POINTS_PER_INCH;
    case 'mm': return value * POINTS_PER_INCH / MM_PER_INCH;
    case 'cm': return value * POINTS_PER_INCH / CM_PER_INCH;
    case 'meters': return value * POINTS_PER_INCH / METERS_PER_INCH;
    default: return value;
  }
}

function fromPoints(points, unit) {
  switch (unit) {
    case 'points': return points;
    case 'inches': return points / POINTS_PER_INCH;
    case 'mm': return points / POINTS_PER_INCH * MM_PER_INCH;
    case 'cm': return points / POINTS_PER_INCH * CM_PER_INCH;
    case 'meters': return points / POINTS_PER_INCH * METERS_PER_INCH;
    default: return points;
  }
}

/**
 * CSS → PDF → CSS round-trip check within 0.01 pt tolerance.
 * @param {number} x — CSS x
 * @param {number} y — CSS y
 * @param {number} w — width
 * @param {number} h — height
 * @param {number} pageHeight
 * @param {number} [rotation=0]
 * @returns {boolean}
 */
export function roundTripOk(x, y, w, h, pageHeight, rotation = 0, pageWidth = null) {
  const pw = pageWidth || pageHeight;
  const pdf = cssToPdfRotated(x, y, w, h, pageHeight, rotation, pw);
  const css = pdfToCssRotated(pdf.x, pdf.y, pdf.width, pdf.height, pageHeight, rotation, pw);
  return Math.abs(css.x - x) <= 0.01 && Math.abs(css.y - y) <= 0.01;
}

/**
 * CSS → PDF conversion with a rotation number (no pdf.js viewport).
 * @param {number} x_css
 * @param {number} y_css
 * @param {number} w
 * @param {number} h
 * @param {number} pageHeight
 * @param {number} rotation — degrees 0, 90, 180, 270
 * @returns {{x:number, y:number, width:number, height:number}}
 */
export function cssToPdfRotated(x_css, y_css, w, h, pageHeight, rotation, pageWidth) {
  if (rotation && rotation !== 0) {
    var pw = typeof pageWidth === 'number' ? pageWidth : pageHeight;
    var r = applyRotation(x_css, y_css, pw, pageHeight, rotation);
    return {
      x: r.x,
      y: pageHeight - r.y - h,
      width: w,
      height: h
    };
  }
  return {
    x: x_css,
    y: pageHeight - y_css - h,
    width: w,
    height: h
  };
}

/**
 * PDF → CSS conversion with a rotation number (no pdf.js viewport).
 * @param {number} x_pdf
 * @param {number} y_pdf
 * @param {number} w_pdf
 * @param {number} h_pdf
 * @param {number} pageHeight
 * @param {number} rotation — degrees 0, 90, 180, 270
 * @returns {{x:number, y:number, width:number, height:number}}
 */
export function pdfToCssRotated(x_pdf, y_pdf, w_pdf, h_pdf, pageHeight, rotation, pageWidth) {
  if (rotation && rotation !== 0) {
    var pw = typeof pageWidth === 'number' ? pageWidth : pageHeight;
    var cssY = pageHeight - y_pdf - h_pdf;
    var r = applyRotation(x_pdf, cssY, pw, pageHeight, -rotation);
    return { x: r.x, y: r.y, width: w_pdf, height: h_pdf };
  }
  return {
    x: x_pdf,
    y: pageHeight - y_pdf - h_pdf,
    width: w_pdf,
    height: h_pdf
  };
}
