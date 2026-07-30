// PdfViewer integration module — plan3.md §3.2
//
// Thin wrapper around pdfjs-dist's viewer components, loaded dynamically
// by PdfViewerHook (T-042) when a document is opened. The pdf.js vendor
// files are copied to priv/static/vendor/pdfjs/ by the assets:vendor
// mise task and served as static assets; esbuild externalizes paths
// starting with /vendor/ so these large libraries stay out of app.js.
//
// Import the ESM viewer components (§3.2 lines 259-262):
// PDFViewer (virtualised scroll container), PDFPageView, EventBus,
// PDFLinkService, PDFFindController, PDFScriptingManager,
// TextLayer, AnnotationLayerBuilder, ScrollMode, SpreadMode.
//
// pdf.js 6.x breaking changes (§3.2 lines 270-274):
//   - 6.0: getDocument() parameter object is mandatory
//   - 6.1: getAttachments() returns a Map; convertToViewportRectangle removed
//   - renderTextLayer is gone; use `new TextLayer({...})`

// Resource URLs — served as static assets from vendor copy (§3.2 lines 251-254)
const CMAP_URL = "/vendor/pdfjs/cmaps/";
const STANDARD_FONT_DATA_URL = "/vendor/pdfjs/standard_fonts/";
const ICC_URL = "/vendor/pdfjs/iccs/";
const WASM_URL = "/vendor/pdfjs/wasm/";
const WORKER_SRC = "/vendor/pdfjs/pdf.worker.mjs";
const SANDBOX_SRC = "/vendor/pdfjs/pdf.sandbox.mjs";

// Cached module references (populated by init())
let _pdfjsLib = null;
let _PDFViewer = null;
let _EventBus = null;
let _PDFLinkService = null;
let _PDFFindController = null;
let _ScrollMode = null;
let _SpreadMode = null;
let _PDFScriptingManager = null;

/**
 * Initialise pdf.js — must be called once before creating a viewer.
 * Sets GlobalWorkerOptions.workerSrc and caches the viewer classes.
 * Safe to call multiple times (idempotent).
 */
export async function init() {
  if (_pdfjsLib) return;

  // Dynamic imports from vendor paths — esbuild externalizes these
  const pdfjsLib = await import("/vendor/pdfjs/pdf.mjs");
  const {
    PDFViewer,
    EventBus,
    PDFLinkService,
    PDFFindController,
    PDFScriptingManager,
    ScrollMode,
    SpreadMode,
  } = await import("/vendor/pdfjs/pdf_viewer.mjs");

  pdfjsLib.GlobalWorkerOptions.workerSrc = WORKER_SRC;

  _pdfjsLib = pdfjsLib;
  _PDFViewer = PDFViewer;
  _EventBus = EventBus;
  _PDFLinkService = PDFLinkService;
  _PDFFindController = PDFFindController;
  _PDFScriptingManager = PDFScriptingManager;
  _ScrollMode = ScrollMode;
  _SpreadMode = SpreadMode;
}

/**
 * Create a new PDFDocument loading task from a URL.
 *
 * Returns the getDocument promise. The caller awaits it and attaches
 * the PDFViewer to the document via setDocument() once resolved.
 *
 * @param {string} url - URL to the PDF bytes
 * @param {object} [opts]
 * @param {string} [opts.password] - Document password for encrypted PDFs
 * @returns {Promise<object>} pdfjsLib.PDFDocumentProxy
 */
export function openDocument(url, opts = {}) {
  if (!_pdfjsLib) throw new Error("pdf.js not initialised — call init() first");

  const getDocumentParams = {
    url,
    cMapUrl: CMAP_URL,
    cMapPacked: true,
    standardFontDataUrl: STANDARD_FONT_DATA_URL,
    iccUrl: ICC_URL,
    wasmUrl: WASM_URL,
    enableXfa: true,
    useSystemFonts: false, // Use embedded fonts
  };

  if (opts.password) {
    getDocumentParams.password = opts.password;
  }

  return _pdfjsLib.getDocument(getDocumentParams).promise;
}

/**
 * Create a pdf.js PDFViewer inside a container element.
 *
 * @param {HTMLElement} container - The viewer container element
 * @returns {{ viewer: PDFViewer, eventBus: EventBus, linkService: PDFLinkService, findController: PDFFindController, scriptingManager: PDFScriptingManager }}
 */
export function createViewer(container) {
  if (!_pdfjsLib) throw new Error("pdf.js not initialised — call init() first");

  const eventBus = new _EventBus();
  const linkService = new _PDFLinkService({
    eventBus,
    externalLinkTarget: 2, // _blank
  });
  const findController = new _PDFFindController({
    eventBus,
    linkService,
  });

  const scriptingManager = new _PDFScriptingManager({
    eventBus,
    sandboxBundleSrc: SANDBOX_SRC,
    wasmUrl: WASM_URL,
  });

  const viewer = new _PDFViewer({
    container,
    eventBus,
    linkService,
    findController,
    textLayerMode: 2, // Enable text layer + enhance
    annotationMode: 2, // Enable annotations
    imageResourcesPath: "/vendor/pdfjs/image-resources/",
    enablePrintAutoRotate: true,
    enableSignatureEditor: true,
    useOnlyCssZoom: false,
    maxCanvasPixels: 4096 * 4096, // §14.1 budget
  });

  linkService.setViewer(viewer);
  scriptingManager.setViewer(viewer);
  findController.setDocument(null);

  return { viewer, eventBus, linkService, findController, scriptingManager };  
}

// Re-export constants and classes for use by the hook
export {
  _pdfjsLib as pdfjsLib,
  _PDFViewer as PDFViewer,
  _EventBus as EventBus,
  _PDFLinkService as PDFLinkService,
  _PDFFindController as PDFFindController,
  _PDFScriptingManager as PDFScriptingManager,
  _ScrollMode as ScrollMode,
  _SpreadMode as SpreadMode,
  CMAP_URL,
  STANDARD_FONT_DATA_URL,
  ICC_URL,
  WASM_URL,
  SANDBOX_SRC,
  WORKER_SRC,
};
