# Quire — Implementation Plan

**A full-parity Soda PDF Desktop clone built entirely on Elixir + Phoenix LiveView.**

| | |
|---|---|
| **Document version** | 3.0 |
| **Date** | 2026-07-29 |
| **Audience** | The coding agent implementing this project |
| **Source of truth for the UI** | 15 reference screenshots of Soda PDF Desktop (Home, backstage, and the ribbon tabs) |
| **Delivery model** | Web-first Phoenix app running **natively on macOS (Apple Silicon)**, with a filesystem abstraction that lets a Tauri desktop build be added later without rework |
| **Runtime environment** | **No containers.** Toolchain via **mise**, a minimal set of system libraries via **Homebrew**, database via a **locally installed PostgreSQL 18** |
| **PDF architecture** | Hybrid — pdf.js/pdf-lib in the browser for interactive work, and a **100% in-BEAM engine layer** (PDFium NIF, Tesseract NIF, native Elixir converters and crypto) on the server. No office suites, no JVM, no Python, no external PDF CLI utilities |

---

## 0. How to use this document

Read sections 1–8 once, in order, before writing any code. They define the
architecture that every feature depends on. Sections 9–13 are per-feature
reference — read the relevant one when you pick up that phase. Section 15 is
the actual work order: **start there once you understand 1–8**, and work
tasks in the numbered order unless a task explicitly says it can be
parallelised.

Conventions used throughout:

- `T-###` — a task ID from §15. Reference these in commit messages.
- **MUST / SHOULD / MAY** — RFC 2119 strength. MUST items are acceptance
  criteria; SHOULD items are strong defaults you may deviate from with a
  written reason in the PR; MAY items are optional.
- File paths are relative to the project root unless absolute.
- Where a version number is given, **pin it**. Versions were verified against
  Hex, npm and crates.io on 2026-07-29.

Three rules that override everything else in this document:

1. **Never call `File.*`, `Path.*`, `System.tmp_dir/0` or `System.cmd/3`
   outside the two abstraction modules defined in §7.1 and §7.2.** This single
   rule is what makes the desktop build (§12) a configuration change rather
   than a rewrite. Enforce it in the local check suite (T-014).
2. **Every capability runs inside the BEAM or inside the browser.** The only
   non-BEAM collaborators in the entire system are PostgreSQL 18 and,
   optionally, the system's Chromium browser (driven by an Elixir library
   over the DevTools protocol). There is no office suite, no JVM, no Python
   interpreter, and no external PDF command-line utility anywhere in the
   stack — not installed, not invoked, not fallen back to. See §3.4. If a
   feature seems to require one, the design took a wrong turn; say so in
   review rather than installing it.
3. **Every version, every tool, every environment variable is declared in
   `mise.toml` or the `Brewfile`.** Without containers, those two files *are*
   the reproducibility story. A tool that only works because it happens to be
   on your machine is a tool that will not work on the next machine. `mise run
   doctor` (T-013) is the enforcement point.

---

## 1. Product goal & scope

Build a browser-based PDF editor that reproduces the structure, ergonomics and
feature set of Soda PDF Desktop: a windowed application shell with a Microsoft
Office-style ribbon, a multi-document tab strip, a backstage ("File") menu, a
Home/start screen with tool tiles and a Recent list, and eleven functional
ribbon tabs.

### 1.1 Feature inventory (from the screenshots)

Every item below is a UI affordance visible in the reference screenshots and
therefore in scope. §9 specifies the implementation of each.

**Window chrome & Quick Access Toolbar** — app logo, undo, redo, open, save,
print, email, new (+), customise-QAT chevron, document title, account avatar
with notification dot, minimise/maximise/close, `Activate now` upsell button,
help, settings.

**Menu bar** — hamburger (backstage), home, and **eleven** tabs: View,
Create & Convert, Fill & Sign, Edit, Page, Comment, Secure, Forms, E-Sign,
OCR, Translate.

**Backstage (File menu)** — New, Open, Save, Save as, Save optimized,
Properties, Print, Print selection, Exit; source picker with Recent / Computer
/ Add account; `Browse…`; This PC breadcrumb; Local Folders (Desktop,
Documents, Downloads, App Files, Current Document Location); Devices and
drives.

**Home screen** — tool tiles: Open PDF, Clipboard to PDF, Merge files to PDF,
Convert to PDF, PDF to Word, PDF to Excel, Add comment, Protect your PDF,
Batch, Customize. Recent panel with `Clear all`, `Sort by`, grid/list toggle,
document thumbnails. Feedback and support floating buttons.

**View** — Continuous (dropdown), Fullscreen, Side by side, Fit page, Fit
width, Actual size, Rotate view, Snapshot, Read aloud, zoom −/percent/+.

**Create & Convert** — New (dropdown), File to PDF, Scan to PDF, Clipboard to
PDF, URL to PDF, Merge, Split PDF, Compress, PDF to Word, PDF to Excel, PDF to
PowerPoint, PDF to Image, Advanced ▸ (PDF to PDF/A, PDF to TXT, PDF to RTF,
PDF to HTML).

**Fill & Sign** — Signature (dropdown), Initials (dropdown), Signer's name,
Signing date, plus a floating palette: Text, Crossmark, Checkmark, Filled Dot,
Line.

**Edit** — Add text, Insert image, Link, Format painter, Select text, Page
number, Watermark, Header and footer, Bates numbers, Remove page marks
(dropdown), Spell check (dropdown), Ruler, Grid, plus a floating text format
bar (font family, size, bold, italic, colour, highlight, strikethrough,
underline, alignment, indent −/+, anchor, overflow, properties, close) and an
`Add Action` modal (Open web page / Open file / Go to page / more).

**Page** — Insert, Extract, Replace, Move, Reverse, Background, Size, Margin,
Export images, Page crop, Remove crop, thumbnail workspace with grid/single
toggle and a zoom slider.

**Comment** — Text, Highlight, Strikethrough, Underline, Sticky note, Pencil,
Attachment, Stamp, Line (dropdown), Oval (dropdown), Advanced (dropdown),
Whiteout, Compare, Export comments.

**Secure** — Restrict Permissions, Digital signature, Create redaction, Apply
redaction, Search and redact, Remove metadata, Sanitize.

**Forms** — Text field, Combo box, List box, Signature, Check box, Radio
button, Button (dropdown), Highlight fields, Form data (dropdown), Reset.

**E-Sign** — Sign your document, Request signature, Inbox (dropdown), My
signature, Manage signers.

**OCR** — Document, Scan and recognize, External image, OCR options.

**Translate** — the tab label is visible but its ribbon was not captured.
§9.11 specifies it from first principles; treat that section as a design
proposal rather than a transcription.

**Document workspace** — left rail (panel toggle, bookmarks), right rail
(search, attachments), document tab strip, page canvas, page navigation
`n / total`, share/help/settings.

### 1.2 Explicit non-goals

- Reproducing Soda PDF's exact logo, wordmark, colour identity or icon set
  (see §2).
- Windows-specific shell integration (drive browsing) in the web build.
  §10.2 specifies the portable equivalent; the literal drive browser only
  becomes possible in the desktop build (§12).
- A print driver / virtual printer.
- **ISO-certified PDF/A generation.** PDF → PDF/A ships as a best-effort,
  honestly-labelled conversion produced and checked entirely in Elixir
  (§3.3, §9.2). Guaranteed, validator-certified conformance is out of scope;
  the product never claims it.
- Desktop scanner driver integration (TWAIN/SANE). Web camera capture is in
  scope; OS-level scanner drivers are a post-1.0 desktop follow-up.
- **Any external document-processing tooling.** No office suite (LibreOffice
  or otherwise), no JVM-based validators, no Python CLIs, no Ghostscript, no
  poppler/qpdf-style utilities. Office conversion, OCR, signing, encryption
  and PDF/A are all implemented in Elixir and in-BEAM NIFs (§3.3). This is a
  deliberate architectural constraint, not a gap to be patched later.
- **PostgreSQL extensions of any kind.** A stock PostgreSQL 18 install with
  zero `CREATE EXTENSION` statements runs every migration (§3.7, §5).
- **Containers and container-based deployment.** This project targets a
  single developer machine. Production deployment is a separate exercise and
  deliberately unspecified here; do not add a `Dockerfile` "just in case" —
  the reproducibility contract lives in `mise.toml` and the `Brewfile` (§3.6).
- **Object storage.** `Storage.Web` ships with a filesystem backend only. The
  S3 backend is a stub with a failing test marked `@tag :skip` so the seam
  stays honest (§7.1).
- **Multi-user / multi-machine operation.** Everything runs on `localhost`,
  one BEAM node, one Postgres. `dns_cluster` stays in the dependency list but
  is inert. Nothing in the design forbids scaling out later; nothing in v1
  tests it. **One consequence to plan around:** E-Sign (§9.9, Phase 10) needs
  an external signer to reach `/sign/:token` from their own machine, which a
  `localhost`-only deployment cannot provide. Build and test that phase behind
  a tunnel (`cloudflared`, `ngrok` or equivalent) pointed at the local
  endpoint, set `PHX_HOST` to the tunnel hostname so generated links are
  correct, and treat "works through a tunnel" as Gate 10's real bar. Do not
  weaken §12.2's origin checking to make it easier.

---

## 2. Legal and branding note — read before Phase 1

Reimplementing an application's *functionality* is legitimate. Copying its
*identity* is not, and it is the kind of thing that gets a project taken down
after the work is done. Two concrete rules:

1. **Do not reuse Soda PDF's name, the red "S" logo, the wordmark, or any of
   its icon artwork.** Pick a project name and generate an original icon set
   (Heroicons and Lucide between them cover ~95% of the glyphs in the
   screenshots). The name chosen at T-001 is **Quire** (OTP app `:quire`,
   module namespace `Quire`), and the accent colour is indigo `#4F46E5`.
2. **Layout, ribbon structure and feature naming are fine to mirror** — these
   are functional and largely industry-standard (Acrobat, Foxit, Nitro and
   Soda all share them). Generic labels like "Fit width" or "Split PDF" carry
   no protection. Avoid copying distinctive *phrasing* verbatim where an
   obvious alternative exists.

(Heroicons is MIT, Lucide is ISC — both permissive; see §8.4.)

If the intent is an internal tool that will never be distributed, the risk is
low but the rules above cost nothing. If it will be published, follow them
strictly.

---

## 3. Technology decisions

### 3.1 Core stack

| Component | Version | Managed by | Why |
|---|---|---|---|
| **mise** | 2026.7.x | Homebrew | Single source of truth for language runtimes, project env vars and task running. Replaces asdf, direnv and `make`. See §3.6. |
| Elixir | `1.20.2-otp-28` | mise | Take the gradual typing — it is worth real money on a codebase this size. **Pin the `-otp-28` build**, not bare `1.20.2`: the OTP-suffixed artefact is precompiled against the matching OTP and avoids a source build. |
| Erlang/OTP | 28.x | mise | 28 preferred. Built from source by kerl on first install — see §3.6 for the macOS OpenSSL flags, and expect 10–20 minutes on an M-series chip. |
| Phoenix | `~> 1.8.9` | Hex | Current stable line. |
| Phoenix LiveView | `~> 1.2.7` | Hex | Gives colocated hooks (`Phoenix.LiveView.ColocatedHook`), which this project leans on heavily. |
| Bandit | `~> 1.12` | Hex | Phoenix 1.8 default adapter. |
| **PostgreSQL** | **18.4** | Homebrew (`postgresql@18`) | Running natively on the machine, started with `brew services`. §3.7 covers what PG18 gives this project — chiefly native `uuidv7()`. **No extensions are required, and none may be added.** |
| Ecto | `~> 3.14.1` | Hex | Declared explicitly, not left to `ecto_sql`'s floor. UUID v7 *generation* (`autogenerate: [version: 7]`, `precision: :monotonic`) landed in 3.14.0, but the helpers §3.7 uses — `to_datetime/1`, `to_unix/2`, `version/1` — landed in **3.14.1**. `ecto_sql ~> 3.13` alone would admit a version that cannot do this and silently break the T-200 schemas. |
| Ecto SQL + Postgrex | `~> 3.14` / `~> 0.22` | Hex | Postgrex speaks PG18's wire protocol without changes; scram-sha-256 is the default auth method and works out of the box. |
| Oban | `~> 2.23` | Hex | Every server-side PDF operation is a job. Non-negotiable — see §7.5. |
| Tailwind CSS | v4 (via `tailwind` Hex package) | Hex | Phoenix 1.8 default. Downloads a standalone darwin-arm64 binary, no Node required for CSS. |
| esbuild | via `esbuild` Hex package | Hex | Phoenix 1.8 default. Must be configured for ESM + code splitting — pdf.js 6.x is ESM-only. |
| Node.js | 24.x LTS | mise | **Not** used to build the app. Needed only for `npm install pdfjs-dist` / `@cantoo/pdf-lib` vendoring (T-038) and for Playwright (T-199). |
| Req | `~> 0.7.1` | Hex | URL fetching, TSA timestamp requests, cloud storage connectors, translation provider calls. 0.7.0 carried breaking changes (`current_request_steps` removed, `run_finch` → `Req.Finch`, `put_plug`/`run_plug` → `Req.Plug`); pin the **0.7.1** line, because `~> 0.7` takes 0.7.0 as its floor and still floats to 0.9.x, which is not a bound at all. |
| Rustler | `~> 0.38`, `runtime: false` | Hex + mise (`rust`) | Builds `Quire.Pdf` (§3.3) from source on every `mix compile`, so **a Rust toolchain is on the happy path, not a fallback**. Also the `EXPDFIUM_BUILD=1` escape hatch and Tauri (§12). It is *not* justified by an OCR NIF — see §3.3. |
| rustler_precompiled | `~> 0.8.4` | Hex | Declared explicitly because it is the component that downloads `ex_pdfium`'s `aarch64-apple-darwin` artefact (ADR 0001). `ex_pdfium` asks for `~> 0.8`, which floats to 0.9.0 — a line it was not developed against, and which changed the download path. Hold the 0.8 line. |
| Rust | `1.91` | mise | Set by **rustler 0.38.0**, whose manifest declares `rust-version = "1.91"`; cargo hard-refuses below it with no override. `lopdf` 0.44.0 needs only 1.88, so rustler is the binding constraint. (Earlier drafts said 1.90 and 1.85; both were wrong.) |

**Strip daisyUI before Phase 1.** Phoenix 1.8.9's generator adds a daisyUI
dependency **and** daisyUI-classed markup throughout `core_components.ex` and
the layouts; `mix phx.gen.auth` (T-200) emits more of it — six more templates,
all daisyUI-classed. The chrome in §8 is bespoke and daisyUI's opinions will
fight you. Removing it therefore means deleting the dep *and* rewriting the
generated markup — run `phx.gen.auth` in Phase 0 **before** the strip, then
clean both generators' output in a single pass in T-025, rather than doing it
twice.

### 3.2 Browser-side PDF stack

| Library | Version | License | Role |
|---|---|---|---|
| `pdfjs-dist` | **6.1.200** | Apache-2.0 | Rendering, text layer, search, annotation editing |
| `@cantoo/pdf-lib` | **2.7.4** | MIT | Client-side document mutation |
| `idb-keyval` | 6.2.2 | Apache-2.0 | Persisting OPFS handles and document metadata |

**Use `@cantoo/pdf-lib`, not `pdf-lib`.** Upstream `pdf-lib` is frozen and —
critically — **cannot open or write encrypted PDFs at all**, which kills the
entire Secure tab. `@cantoo/pdf-lib` 2.7.4 is a maintained MIT fork that
implements RC4, AES-128 (`AESV2`) and AES-256 (`AESV3`) in `PDFSecurity`,
ships a `DecryptStream`, and exposes `PDFDocument.encrypt/1`.

**pdf.js integration notes that will save you a day each:**

- 6.1.200 is **ESM-only**. There is no UMD/CJS bundle. Configure esbuild with
  `format: :esm`, `splitting: true`, and emit `pdf.worker.mjs` as a separate
  entry point assigned to `GlobalWorkerOptions.workerSrc`.
- You **must** copy `cmaps/`, `standard_fonts/`, `iccs/` and `wasm/` from the
  package into `priv/static/vendor/pdfjs/` and pass `cMapUrl`,
  `standardFontDataUrl`, `iccUrl` and `wasmUrl` to `getDocument`. Missing
  these produces silent blank pages on CJK and JPEG2000 documents.
- There is **no WebGL renderer** — canvas 2D only. Acceleration in 6.x comes
  from WASM (JBIG2, OpenJPEG, QCMS) and the native `ImageDecoder`. Your
  performance lever is canvas count, not GPU flags. Budget ~3.4 MB of canvas
  memory per letter-size page at 1× and virtualise aggressively (§14).
- Import the **viewer components**, not the full viewer app:
  `pdfjs-dist/web/pdf_viewer.mjs` exports `PDFViewer`, `PDFPageView`,
  `EventBus`, `PDFLinkService`, `PDFFindController`, `PDFScriptingManager`,
  `TextLayerBuilder`, `AnnotationLayerBuilder`, `RenderingStates`,
  `ScrollMode`, `SpreadMode`. This gives you virtualised scrolling, search and
  layer orchestration for free, without inheriting `viewer.html`.
- `AnnotationEditorLayer` ships exactly five editor types: `FreeTextEditor`,
  `InkEditor`, `StampEditor`, `HighlightEditor`, `SignatureEditor`. Combined
  with `PDFDocumentProxy.saveDocument()` this natively round-trips free text,
  ink, image stamps, highlights, drawn signatures and **AcroForm filling**.
  Everything else (page ops, redaction, body-text reflow) goes elsewhere.
- Breaking changes to be aware of: 6.0 made the `getDocument` parameter object
  mandatory and removed `PDFDocumentProxy.destroy`; 6.1 changed
  `getAttachments()` to return a `Map` and removed
  `convertToViewportRectangle`.
- `renderTextLayer` is gone. Use `new TextLayer({...})`.

**Considered and rejected for the browser:**

- **MuPDF.js** — the most capable browser PDF engine by a wide margin, but it
  is **AGPL-3.0-or-later** and its WASM binary would be *conveyed* to every
  end user. **Do not ship it.**
- **EmbedPDF (MIT, PDFium-WASM)** — genuinely attractive; it offers true
  client-side redaction, which pdf.js does not. Rejected as the *primary*
  engine only because pdf.js's annotation editor and form support are more
  mature. **Reconsider it for the Secure tab** if server-side redaction
  latency (§9.7) proves unacceptable.

### 3.3 The in-BEAM PDF engine — the heart of this architecture

Every server-side capability is implemented as a Hex dependency running
inside the BEAM (pure Elixir or a dirty-scheduled NIF), or as Elixir code
written for this project. This table is the complete server-side engine
inventory — if a feature needs something not on it, the feature's design is
wrong, not the table.

| Component | Version | License | Form | Owns |
|---|---|---|---|---|
| **PDFium** via `ex_pdfium` | `== 0.5.1` (PDFium **144.0.7543.0**, pdfium-render **0.8.37**) | MIT / BSD-3 | Rustler NIF, precompiled, `libpdfium` bundled | Page rasterisation (thumbnails, previews, print renders), text extraction with per-character bboxes, search, page geometry, **outline read**, attachment enumeration/extraction, **AcroForm introspection (read)**, annotation inspection, image extraction, page import/splice (merge, split, insert, extract, replace, reorder, reverse), **page box read**, page-object creation (text, vector, image) for stamps/watermarks/headers/footers/Bates/page numbers, annotation flattening, `rotate_page/3` and `object_display_rotation/3`, `links/2`, `permissions/1` (read), `signatures/1`, `page_objects/2`, and **PDF save without linearization** |
| **`Quire.Pdf`** — PDF object model, over `lopdf` 0.44.0 (written for this project) | lopdf `0.44.0`; built from source by `use Rustler` | MIT | **Rustler NIF, compiled from source** (needs Rust ≥ 1.91, §3.1) | Raw PDF structure read *and write*: catalog and arbitrary dictionary modification, `IncrementalDocument` appends over the original bytes, `save_modern` with **object streams + xref streams**, `authenticate_password/1` for encrypted input, and `Bookmark`/`Outline` with `add_bookmark()`/`build_outline()`. Owns **outline write** (`Quire.Pdf.Outline`), and `/AP` appearance-stream generation plus `/AcroForm` re-attachment after page import (`Quire.Pdf.AcroForm`, per ADR 0003 D5 — `Quire.Compose` does NOT own `/AP`). This is the foundation `Quire.Compose`, `Quire.PdfA`, `Quire.SecurityHandler` and `Quire.Pades` were already assuming and nobody owned |
| **Tesseract** via `image_ocr` | `== 0.2.0` | Apache-2.0 (binding); Tesseract itself Apache-2.0 | C++ NIF over Homebrew Tesseract 5.5.3 + Leptonica 1.87.0 | OCR recognition, per-word confidence and bounding boxes, auto-rotate via `osd.traineddata`, 100+ languages via tessdata packs (`eng` vendored in `priv/`, further packs on demand) |
| **`image` / `vix`** (libvips) | `image ~> 0.72.0` / `vix == 0.40.0` | MIT (bindings) / **LGPL-3.0-or-later** — the bundled libvips is a statically combined work, see §3.5 | Precompiled NIF with a bundled `libvips-cpp.8.18.3.dylib` | Image format normalisation (HEIC/TIFF/BMP/WebP → PNG/JPEG), deskew, denoise/clean for OCR preprocessing, image downscale and recompression for Compress, PNG/JPEG/TIFF/WebP output for PDF→Image |
| **Native OOXML/ODF reader** (`Quire.Office.Reader`, written for this project) | — | project code | Pure Elixir: ZIP (`:zip`) + XML (`Saxy`) | Reading .docx/.xlsx/.pptx/.odt/.ods/.odp/.rtf/.csv/.txt/.md into an intermediate layout model for File→PDF |
| **Native OOXML writers** (`Quire.Office.Writer.*`, written for this project; `elixlsx` MAY be used for .xlsx) | — | project code (+ `elixlsx` MIT) | Pure Elixir | Generating .docx/.xlsx/.pptx/.rtf from extracted PDF content for PDF→Word/Excel/PowerPoint/RTF |
| **chromic_pdf** | 1.17.1 | Apache-2.0 | Hex library driving the **system Chromium** over CDP | URL→PDF and HTML→PDF rendering (the File→PDF back end and PDF→HTML print paths). Chromium is a browser the user already has — the only external process the app ever spawns besides Postgres |
| **Native PAdES signing** (`Quire.Pades`, written for this project) | — | project code | Elixir over OTP `:public_key` / `:crypto`, with `Quire.Pdf` for byte-range and DSS structure writes | CMS (PKCS#7) detached signatures over PDF byte ranges, PKCS#12 keystore parsing, PAdES B-B and B-T levels, RFC 3161 timestamping via Req, DSS/VRI appending for B-LT, signature validation and difference analysis (§9.7) |
| **Native security handler** (`Quire.SecurityHandler`, written for this project) | — | project code | Elixir over `:crypto`, with `Quire.Pdf` for `/Encrypt` dictionary read/write | AESV2/AESV3 encryption and decryption, owner/user passwords, permission flags, per ISO 32000-2 §7.6 (§9.7) |
| **Native PDF/A module** (`Quire.PdfA`, written for this project) | — | project code | Elixir over the PDFium NIF for inspection and `Quire.Pdf` for structure writes | Best-effort PDF/A-2b conversion (font embedding verification, OutputIntent/ICC injection, XMP metadata, MarkInfo, forbidden-feature removal) plus a built-in structural conformance report (§9.2) |
| **Native text reflow & stamping** (`Quire.Compose`, written for this project) | — | project code | Elixir over `Quire.Pdf` | Content-stream generation for overlay/underlay stamping, text runs, translation overlay/sidecar output (§9.5, §9.11). `/AP` appearance-stream generation belongs to `Quire.Pdf.AcroForm`, not here (ADR 0003 D5) |

**How the pieces fit.** PDFium is the primary *rendering and inspection*
engine and it is a very capable one: its page-import API implements
merge/split/reorder directly, its page-object API draws stamps and watermarks
in-process, its text API produces the spans that power search, Compare,
Translate and Edit mode, and its save API produces the output files.
Everything PDFium does not do — OCR, image work, Office formats, signatures,
encryption, PDF/A — is either a second in-BEAM NIF (`image_ocr`, libvips,
`Quire.Pdf`) or Elixir built on OTP's crypto and ZIP/XML tooling. There is no
point in the system where work leaves the VM to a third-party CLI.

**What PDFium cannot do, verified against the headers it actually ships.**
The row above was rebuilt from source in ADR 0003 — `deps/ex_pdfium/lib/ex_pdfium.ex`,
`native/ex_pdfium/src/lib.rs`, and pdfium-render 0.8.37's vendored PDFium
public C headers at `include/pdfium_7543/`. Of the verbs the old row claimed,
**22 are present, 9 partial, 2 missing**, and neither missing verb is
reachable by forking:

- **Outline write is absent from PDFium's public API.** `fpdf_doc.h` exposes
  exactly seven `FPDFBookmark_*` symbols and all seven are getters (`Find`,
  `GetAction`, `GetCount`, `GetDest`, `GetFirstChild`, `GetNextSibling`,
  `GetTitle`); grepping all 22 headers returns the same seven. pdfium-render
  mirrors it — `PdfDocument` has `bookmarks()` and **no** `bookmarks_mut()`,
  on adjacent lines to `attachments_mut()`, `fonts_mut()` and `pages_mut()`.
  **Owner: `Quire.Pdf.Outline`** (server-authoritative, so §7.4 undo payloads
  are unaffected). It is *not* client-side: `@cantoo/pdf-lib` 2.7.4 has no
  outline or bookmark API of any kind.
- **Linearizing save is likewise absent.** PDFium can *detect* linearization;
  it cannot produce it. `lopdf` cannot either. **Linearization is therefore
  dropped as a product capability** — see §9's Compress row. The
  linearization *read* stays, for the Properties dialog.
- **Page box set and form-field set are reachable but unbound.**
  pdfium-render exposes `boundaries_mut().set_media/crop/bleed/trim/art`,
  text/checkbox/radio value setters and the public `PdfiumLibraryBindings`
  trait; `ex_pdfium` simply does not surface them. Route: a PR to
  `jtippett/ex_pdfium` (active, 0.4.1 → 0.5.1 in three weeks), vendored fork
  as fallback. A from-source NIF build measures 13.85 s, so build cost is not
  the objection — the objection is that a fork must vendor `libpdfium`
  (5.5 MB per target) and run its own release matrix. Form XObject /
  place-a-page-on-a-page belongs to the same PR, which means §9's "background:
  another PDF" needs no rasterise fallback.
- **`/V` without `/AP` silently loses user input.** PDFium's setter writes
  `/V` but never regenerates `/AP`, and `flatten/1` bakes `/AP` while ignoring
  `/V` entirely. A `/V`-only write — including the obvious "set `/V` and
  `NeedAppearances`" approach — flattens to the *old or empty* appearance.
  **Hard rule: any `/V` write MUST also write `/AP`** before the document is
  flattened or rasterised by anything other than `render_page/3`.
- **Crop-origin coordinate frame.** On a non-zero-origin CropBox every spatial
  result (text, search, annotation, image, link bounds) is in the **MediaBox**
  frame while `render_page/3` rasterises the **CropBox** region, and
  `ExPdfium.bounds_to_pixels/3` does not reconcile them. `Quire.Render.Pdfium`
  must subtract `boxes.crop` (falling back to `boxes.media` — PDFium does not
  fall back) and compose page `/Rotate`. Needs a `crop_nonzero_origin.pdf`
  fixture and a **Gate 2 exit criterion**.
- **`/AcroForm` and `/Outlines` do not survive page import.** `append/2` and
  `extract_pages/2` drop them while leaving widget annotations behind, so the
  output *looks* like a form and is not one. `Quire.Pdf.AcroForm` re-attaches
  after import; §9's Merge row therefore reads "bookmark **and form**
  handling".
- **Print-intent rendering is partial.** `render_page/3` has no print flag;
  `PdfRenderConfig::use_print_quality` exists in the crate but is unbound.
  Fold it into the same upstream PR.

⚠️ **PDFium's effective parallelism is 1, and that is a property of the
binding, not of the queue.** `deps/ex_pdfium/native/ex_pdfium/src/lib.rs:201`
declares `static PDFIUM_LOCK: Mutex<()>`, and **44 of the 45 NIFs acquire it**
(the sole exception, `set_dynamic_lib_dir` at `lib.rs:351`, is dev/test-only
and touches no document). Every PDFium call in the VM is serialised behind
that one mutex. This is orthogonal to dirty schedulers — all 45 NIFs are
correctly `DirtyCpu`, so BEAM scheduler health is fine; the constraint is
throughput. It is also very likely *correct*: upstream PDFium is not
thread-safe globally. §7.5 sizes the queues to it and §14.1 accounts for the
memory it pins.

**The NIF discipline (applies to `ex_pdfium`, `image_ocr`, `vix` and the
project's own `Quire.Pdf`).** NIFs are the only way to get this performance
natively, and they come with two BEAM-specific hazards that Phase 0 exists to
defuse:

- **Scheduler stalls.** Any NIF that can run longer than ~1 ms MUST be marked
  `DirtyCpu` (CPU work) or `DirtyIo`. Rasterising a page or recognising OCR
  text will blow past the budget on a normal scheduler and freeze LiveView
  under load. T-021 and T-022 verify this empirically for each NIF before it
  touches a request path; if a NIF cannot be dirty-scheduled, patch it or
  wrap the call in a `Port`-style isolation — do not ship a stall. Both
  `ex_pdfium` (45/45) and `image_ocr`'s two recognition entry points already
  declare dirty-CPU, so those gates should pass by construction — but
  `image_ocr`'s `init_nif` runs on a **normal** scheduler while loading a
  ~4 MB traineddata file, and moving it into a pool worker does not fix that
  (`init_worker/1` is itself a synchronous normal-scheduler call). T-022 must
  time it against §14.1.
- **VM crashes.** A segfault in a NIF takes the whole BEAM down. Mitigations:
  pin exact versions, run the full fixture corpus (§13) through every NIF in
  Phase 0 as a crash-fuzz pass, and — for OCR specifically, which is the
  longest-running and least trusted input path — keep the option of running
  the `:ocr` queue on a **second, hidden BEAM node** (plain Erlang
  distribution, one line of config on localhost) so a crash kills a worker
  node and not the app. This is a configuration option, not extra
  infrastructure: distribution is native to the runtime.

**Rejected for the server side, for the record:** any external office suite
(replaced by the native OOXML reader/writers — see R-03 for the fidelity
trade), any Java-based PDF/A validator (replaced by the built-in Elixir
conformance report), any Python OCR/signing CLI (replaced by the Tesseract
NIF and `Quire.Pades`), `pdftk` (upstream dead), `pdf_generator` (Hex,
dead), `pdf2htmlEX` (dead), MuPDF in any form (AGPL).

### 3.4 The native-Elixir contract — what may be added and what may not

This project is deliberately strict about its dependency surface, because the
failure mode of PDF tooling is "one convenient install away from a JVM, a
Python runtime and an AGPL binary." The contract:

**Allowed without review:**

- Any Hex package (pure Elixir, or a NIF under MIT/BSD/Apache) that runs
  inside the BEAM. **The licence that matters is the artefact's, not the Hex
  package's.** `vix` is the worked example: it declares MIT on Hex and ships a
  17.7 MB `libvips-cpp.8.18.3.dylib` that is a Combined Work under
  LGPL-3.0-or-later (§3.5). A Hex package whose *precompiled binary* carries
  copyleft is **not** covered by this clause and falls under "allowed only
  with an ADR" below.
- PostgreSQL 18, stock, no extensions.
- The user's installed Chromium/Chrome browser, driven over CDP by
  chromic_pdf, with an explicit configured executable path. If no Chromium is
  present, URL→PDF and Office→PDF degrade with a clear message; everything
  else keeps working.

**Allowed only with an ADR:**

- A system C library required by a NIF (e.g. Tesseract + tessdata via
  Homebrew if the NIF does not vendor it). It must be declared in the
  `Brewfile`, version-asserted by `mise run doctor`, and surfaced in
  Settings → About. **ADR 0002 is that ADR for `image_ocr` + Homebrew
  Tesseract**; note it also makes `brew "pkgconf"` mandatory, not optional —
  `image_ocr`'s Makefile shells out to `pkg-config`, Xcode CLT does not ship
  it, and it is a *build-only* dependency of the tesseract formula, so
  pouring the bottle does not install it.
- A Hex package shipping a precompiled binary under any copyleft licence,
  however weak. The ADR must record what `otool -L` and the artefact
  contents actually show — not what the package's Hex `licenses` field
  claims — and must name where the resulting obligation is discharged.
  **`vix` has no standalone ADR; its evidence table is in §3.5** (verified
  against the actual artefact on this machine) and the discharge decision is
  in §12.1 step 9. Those two sections together satisfy the rule's intent.
- Any npm package, under the same licence bar as Hex.

**Never allowed:**

- A JVM, a Python or Ruby runtime, an office suite, or any external PDF/CLI
  utility (Ghostscript, poppler, qpdf, mutool, pdftk, ocrmypdf,
  LibreOffice/unoserver, veraPDF, hunspell, unpaper, and friends). The
  capabilities they would have provided are owned by §3.3's in-BEAM layer.
- AGPL or GPL code linked into the BEAM or shipped to the browser.
- Any `CREATE EXTENSION` in any migration.

### 3.5 Licensing rules — hard constraints

| Class | Components | Rule |
|---|---|---|
| **Permissive** — link, bundle, ship | pdf.js, @cantoo/pdf-lib, PDFium, ex_pdfium, pdfium-render, Rustler, lopdf (and `Quire.Pdf` over it), Tesseract, image_ocr, chromic_pdf, Saxy, elixlsx, Oban, the Phoenix stack, and the vix/image *bindings* | No constraints. |
| **Weak / library copyleft** | **The libvips artefact bundled inside `vix`** — `libvips-cpp.8.18.3.dylib`, conveyed under **LGPL-3.0-or-later** as a statically Combined Work | Attribution and licence text (T-180), **and** the LGPLv3 §4 relink duty. **Do not restate the mechanism here — §12.1 step 9 is the single home for that decision.** |
| **Weak / file-level copyleft** | cairo, inside the same dylib | Dual-licensed; cairo is used unmodified, so the file-level obligation is satisfied by shipping its licence text. **Confirm the exact MPL version at T-180** — upstream cairo is `LGPL-2.1-only OR MPL-1.1`, and this plan does not assert 2.0 without evidence. |
| **AGPL / GPL** | none — verified against Hex metadata for all 71 deps. ⚠️ Caveat: licences are from upstream declarations, not artefact inspection — the bundled `libvips-cpp.8.18.3.dylib` ships zero licence text (confirmed: `strings` over the 17.7 MB binary yields no hits for GPL / "General Public License" / "Mozilla Public"). The component-level attributions in the table below depend on sharp-libvips' own declaration, not on anything readable from the binary we ship. | Every Hex dependency resolves to Apache-2.0 / MIT / BSD / ISC. **However, the AGPL/GPL gate as asserted here rests on upstream declarations, not on artefact evidence** — the artefact contains no licence files of any kind. The gate earns "passes" only once T-180 pins the sharp-libvips licence set in-repo AND T-005 confirms libimagequant is on the permissive 2.4.x line. Until then, treat LGPL-3.0-or-later as the operative constraint, and libimagequant as an unverified risk to this row. |

⚠️ **The "LGPL-2.1, dynamically linked" claim that used to sit in this table
was wrong on both halves, and the mitigation it carried — "precompiled vix
artefacts satisfy this as shipped" — was false.** Re-verified on this machine:

| What was checked | Command | Result |
|---|---|---|
| What the artefact contains | `tar tzf vix-nif-2.17-aarch64-apple-darwin-0.40.0.tar.gz` | Exactly two files: `vix.so` and `precompiled_libvips/lib/libvips-cpp.8.18.3.dylib`. **No licence texts, no source, no relink kit.** |
| Where it comes from | `deps/vix/build_scripts/precompiler.exs:20–23` | `akash-akya/sharp-libvips`, release tag `v8.18.3-rc1` — a fork of `lovell/sharp-libvips`, which conveys the combined build under **LGPL-3.0-or-later**. Upstream libvips alone is LGPL-2.1-or-later, but the distributor has already elected v3. |
| Whether it is dynamically linked | `otool -L …/libvips-cpp.8.18.3.dylib` | Links **only** macOS system libraries (`libSystem`, `libc++`, `libobjc`, `libiconv`, `libresolv`, Foundation/CoreFoundation/AppKit/CoreGraphics/CoreServices/CoreText). There is no second dylib in the bundle — every third-party dependency is **statically inside** this one 17.7 MB binary. |
| What is statically inside it | `nm -gU` exported symbols + `strings` | glib/gobject/gio (`g_*`), pango (`pango_*`), cairo (`cairo_*`), librsvg (`rsvg_*`), libexif (`exif_*`), **libheif (`heif_*`)**, harfbuzz (`hb_*`), freetype (`FT_*`), fontconfig (`Fc*`), libpng 1.6.58, libjpeg (`jpeg_*`), libtiff 4.5.1, libwebp (`WebP*`), libarchive 3.8.7, lcms2, libaom (`aom_*`), libimagequant (`liq_*`), cgif, nsgif, libxml2 (`xmlParse*`), zlib-ng, **fribidi (LGPL-2.1-or-later, `_fribidi_get_bidi_type` + 7 more), libffi (MIT, 28 `_ffi_*` exports), highway (Apache-2.0, sharp-libvips build path in strings)**. |

The one dynamic boundary that does exist — `vix.so` → `@rpath/libvips-cpp.8.18.3.dylib`
under `LC_RPATH @loader_path/precompiled_libvips/lib` — is **inside a single
artefact we redistribute**, so it is not the LGPL §4(d)(1) "uses a suitable
shared library mechanism" escape by itself; the copyleft components are static
within the dylib on the far side of it. **libheif alone is LGPL-3.0-or-later**,
which is what forces the whole combination to v3 (the LGPL-2.1-**or-later**
components upgrade cleanly; glib, pango, librsvg and libexif are all
`-or-later`).

**What the table above proves, and what it does not.** The *structural* facts
— one dylib, no other dylibs, those symbols statically inside it, that source
repo and tag, no licence files in the artefact — were all reproduced on this
machine with the commands shown, and they are what overturn "dynamically
linked". The *licence attributions* for the individual components (libheif =
LGPL-3.0-or-later, glib/pango/librsvg/libexif = LGPL-2.1-or-later, cairo =
dual) come from those projects' own upstream declarations, **not** from
anything inside the artefact, because the artefact ships no licence texts at
all. That gap is itself the finding: we redistribute a binary whose licence
we cannot read from the binary. **T-180 must obtain the licence set from
`akash-akya/sharp-libvips` `v8.18.3-rc1` directly and pin it in-repo**, and
that is also when cairo's exact MPL version gets settled. Until then, treat
LGPL-3.0-or-later as the operative constraint — it is the strictest of the
candidates and the one sharp-libvips itself elects.

**Additional uncertainty: libimagequant's licence.** The table lists
`libimagequant (liq_*)` with no licence annotation. libimagequant
re-licensed to GPL-3.0-or-later after the 2.4.x line — which would
falsify the "AGPL/GPL: none" row. The exported API
(`_liq_quantize_image`, `_liq_write_histogram_control_points`) looks
2.x-shaped, so the dylib likely carries the permissive 2.4.1 that
sharp-libvips pins, but this plan asserted the gate PASSES without
confirming it. **T-005 must verify the pinned sharp-libvips version
and assert it stays on the 2.4.x (permissive) line.**

**Why this matters, in one sentence:** LGPLv3 §4 inherits GPLv3 §6 Installation
Information, so conveying a signed, sealed `.app` containing statically
combined LGPLv3 code triggers a relink duty that this plan previously assumed
away. That lands on §12 (packaging), T-005 (the scanner) and T-180
(attribution). **The decision is recorded once, at §12.1 step 9.**

### 3.6 Local development environment (macOS)

**Target: macOS 15+ on Apple Silicon.** Everything below is native `arm64`; no
Rosetta, no emulation, no containers. An Intel Mac will work but several
prebuilt artefacts (the NIFs, the Tailwind and esbuild standalone binaries,
Chromium for Playwright) are slower or need a source build.

#### 3.6.1 Bootstrap order

The order matters — later steps depend on earlier ones being on `PATH`.
Appendix B contains the files; the sequence is:

1. Xcode command line tools (kerl needs a compiler to build OTP).
2. Homebrew.
3. mise, then let it own every language runtime from here on.
4. System libraries + database via the committed `Brewfile`.
5. Language runtimes via the committed `mise.toml` (`mise trust`,
   `mise install`).
6. Project setup: deps, database, assets, fixture corpus (`mise run setup`).
7. Prove the machine is actually ready (`mise run doctor`).

`mise run doctor` is T-013's CLI face. It must exit non-zero on any missing
or wrong-versioned component, and it is the first thing to run when anything
behaves strangely.

#### 3.6.2 What mise owns, and what it does not

**mise owns** language runtimes (Erlang, Elixir, Node, Rust), project
environment variables, and task running. `mise.toml` is committed;
`.mise.local.toml` is gitignored and holds anything machine-specific or
secret (API keys for the translation provider, a TSA URL, the Chromium
executable path, your Postgres username if it is not `$USER`).

**mise does not own** the C-library world. PostgreSQL, OpenSSL and (if the
NIF needs it) Tesseract/tessdata come from Homebrew, pinned by the
`Brewfile` plus `brew bundle --no-upgrade`. This is the seam where
reproducibility is weakest — `brew upgrade` on an unrelated formula can move
a native library underneath you. Mitigations: `mise run doctor` asserts exact
versions on every run, and `Quire.Engine.versions/0` (§7.2) captures them
at boot and surfaces them in Settings → About, so a behaviour change after an
upgrade is diagnosable in seconds instead of hours.

#### 3.6.3 Erlang from source: the macOS OpenSSL flag

mise builds OTP with kerl, and kerl on macOS will not find Homebrew's OpenSSL
on its own. Set `KERL_CONFIGURE_OPTIONS` in `mise.toml` with
`--with-ssl` pointing at `brew --prefix openssl@3`, plus `--disable-debug`,
`--disable-silent-rules`, `--without-javac`, `--enable-shared-zlib` and
`--enable-dynamic-ssl-lib`. Without this, `crypto` fails to build and the
error message points nowhere useful. `--without-javac` is deliberate: nothing
here needs JInterface. **`wxWidgets` is likewise not needed** — the desktop
build uses Tauri (§12), which is the only thing that could have required an
OTP built with `:wx`. That saves a large, fragile chunk of the OTP build.

#### 3.6.4 Running the stack

There is no `docker compose up`, and — unlike most PDF stacks — there are no
resident helper services either. Exactly two long-lived processes:

| Process | Command | Lifecycle |
|---|---|---|
| PostgreSQL 18 | `brew services start postgresql@18` | launchd, survives reboot. |
| Phoenix | `mise run server` (`iex -S mix phx.server`) | Foreground. |

Chromium is spawned on demand by chromic_pdf for the duration of a conversion
job and exits afterwards; nothing else ever runs.

#### 3.6.5 Where files live

| What | Path | Notes |
|---|---|---|
| Repo | `~/code/quire` (or wherever) | |
| Document storage | `<repo>/_data/storage` | Gitignored. `Storage.Web` filesystem backend root (§7.1). Override with `QUIRE_DATA_DIR`. |
| Scratch / temp | `$TMPDIR/quire/<op_id>` | macOS gives each user a private `$TMPDIR`. Per-operation subdirectory, removed in an `after` block. |
| tessdata | `image_ocr`'s resolution: `eng` is vendored in the package's `priv/`; further packs are fetched on demand. Homebrew `share/tessdata` supplies `osd.traineddata`, which auto-rotate needs | Install language packs on demand in T-139 rather than all 100+ up front (~1.5 GB). |
| Postgres data | `$(brew --prefix)/var/postgresql@18` | |
| Fixture corpus | `<repo>/test/fixtures/pdfs` | Committed (§13, T-016). |

Keep storage inside the repo rather than in `~/Library/Application Support`.
It is gitignored either way, and having it one `ls` away is worth more during
development than tidiness. The desktop build (§12) is where
`~/Library/Application Support/Quire` becomes correct, and by then
`Storage.Local` owns that decision.

#### 3.6.6 macOS gotchas that will cost you time

- **File descriptors.** The default `ulimit -n` is 256 on macOS. A LiveView
  app with a page-render pipeline and a virtualised viewer will exhaust that.
  Set `ulimit -n 8192` in `mise.toml`'s task environment and assert it in
  `mise run doctor`.
- **Gatekeeper.** Anything downloaded outside Homebrew dies with a misleading
  "killed: 9" (SIGKILL, exit 137). On older macOS the cause is
  `com.apple.quarantine` and `xattr -dr com.apple.quarantine <path>` fixes it.
  **On macOS 26+ that is not enough** — the attribute is
  `com.apple.provenance`, which `xattr` cannot remove, and `spctl -a` reports
  the vendor's own linker-signed Mach-O as `invalid signature`. Re-sign ad hoc
  instead: `codesign --force --sign - <path>`. Note `xattr -cr` can itself
  invalidate an ad-hoc signature, so reach for `codesign` first. This is
  automated as `mise run assets:resign`, called from `mise run setup` and
  asserted by `mise run doctor`. Homebrew-installed binaries are already clear.
- **`PATH` is not portable across launch contexts.** Launched from a
  terminal, the BEAM inherits your shell `PATH`. Launched from Finder,
  launchd or a future Tauri shell, it does not. The only external executable
  this project resolves is Chromium: declare its absolute path in config
  (`config :chromic_pdf, chrome_executable: …`), never rely on discovery.
- **Case-insensitive filesystem.** APFS is case-insensitive by default. A
  module referenced as `Quire.Storage.Ref` will compile against a file
  named `ref.ex` *or* `Ref.ex`, and the mistake only surfaces on a
  case-sensitive machine later. `mix compile --warnings-as-errors` does not
  catch it; a naming convention and review do.
- **Spotlight indexing `_data/` and `_build/`.** Thousands of scratch PDFs
  will be indexed and re-indexed. Add both to System Settings → Spotlight →
  Privacy, or `touch _data/.metadata_never_index`.
- **App Nap / thermal throttling.** A 500-page render benchmark (T-058) run
  on battery, lid-closed, will produce numbers you cannot reproduce.
  Benchmark plugged in, and record it in the ADR.

### 3.7 What PostgreSQL 18 buys this project

**`uuidv7()` is native.** This design wants UUID v7 primary keys for index
locality — time-ordered UUIDs keep B-tree inserts on the right-hand edge
instead of scattering them, which matters for the append-only
`document_revisions` and `edit_operations` tables that this design leans on
hardest. PG18 ships `uuidv7()` as a built-in function — a core function, not
an extension — so no extension and no Elixir-side library is strictly
required. **Recommended pattern:** generate in Elixir (via
`Uniq.UUID.uuid7/0`) so that `Repo.insert_all/3` and changeset inserts behave
identically and nothing depends on a DB round-trip for an ID, and set
`DEFAULT uuidv7()` on the column as a backstop for hand-written SQL and
migrations. Do not mix the two silently — pick Elixir-side generation as the
rule and document the default as a safety net.

**`RETURNING` can see `OLD` and `NEW`.** PG18 lets an `UPDATE ... RETURNING`
reference both the pre- and post-update row. This is a direct fit for §7.4's
journal: every operation must carry an `inverse` payload sufficient to undo
it, and for update-shaped operations the inverse *is* the old row. Capturing
both halves in one statement removes a read-then-write race that would
otherwise need a transaction and a `SELECT ... FOR UPDATE`. Use it in
`Editing.apply/2` for `annot.update`, `form.update_field` and `text.edit`.

**Generated columns for full-text search.** A `STORED` generated `tsvector`
column plus a GIN index gives the search panel a server-side fallback for
documents too large to search entirely in the client's pdf.js
`PDFFindController`, with no extension and no trigger to maintain. PG18 also
adds `VIRTUAL` generated columns (now the default for new generated columns) —
**do not use VIRTUAL here**, virtual columns cannot be indexed, which defeats
the entire purpose. Write `GENERATED ALWAYS AS (...) STORED` explicitly.

**Not used, deliberately:**

- **Any extension.** A stock `brew install postgresql@18` with zero
  `CREATE EXTENSION` calls must be sufficient to run every migration. Assert
  this in T-006: if a migration needs an extension, the design took a wrong
  turn.
- **Asynchronous I/O tuning.** PG18's headline async-I/O feature is real, but
  `io_uring` is Linux-only; on macOS `io_method` falls back to `worker`,
  which is the default and fine. Do not spend time on it.

**Local configuration.** The Homebrew defaults are adequate. Two changes
worth making in `postgresql.conf` for a development laptop:
`shared_buffers = 512MB` and `work_mem = 16MB` (the default 4MB makes the
`Compare` feature's large sorts spill to disk). Leave `fsync` alone. Use a
separate `quire_test` database and `MIX_ENV=test mix ecto.reset`
instead.

---

## 4. System architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ BROWSER                                                             │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ LiveView-rendered chrome (ribbon, backstage, tabs, panels)    │  │
│  └───────────────────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ Colocated hooks (LiveView 1.2)                                │  │
│  │   PdfViewerHook  → pdf.js PDFViewer + EventBus + FindCtrl     │  │
│  │   AnnotEditHook  → PDFViewer.annotationEditorMode + EventBus  │  │
│  │   DocMutateHook  → @cantoo/pdf-lib                            │  │
│  │   OpfsCacheHook  → OPFS scratch storage                       │  │
│  └───────────────────────────────────────────────────────────────┘  │
└───────────────▲──────────────────────────────────┬──────────────────┘
                │ LiveView diffs / events          │ HTTP range + upload
┌───────────────┴──────────────────────────────────▼──────────────────┐
│ PHOENIX  (one BEAM node — all engines run in this VM)               │
│  WorkspaceLive ─ owns tab strip, ribbon state, backstage            │
│    └─ DocumentLive (one per open doc, live_component)               │
│         └─ Ribbon tab components (11) + floating toolbars           │
│                                                                     │
│  Contexts:  Documents · Editing · Annotations · Forms · Security    │
│             Conversion · Ocr · Signing · Esign · Translation        │
│             Batch · Cloud · Accounts · Licensing                    │
│                                                                     │
│  Per-document: EditSession GenServer (undo/redo journal, §7.4)      │
│  Registry + DynamicSupervisor keyed by {document_id, user_id}       │
│                                                                     │
│  Storage behaviour (§7.1) ──┬── Web adapter ─┬─ :filesystem (now)   │
│                             │                └─ :s3 (later, stub)   │
│                             └── Local adapter (desktop, §12)        │
│  Engine behaviours (§7.2/7.3)                                       │
│    Pdf      → Quire.Pdf — Rustler NIF over lopdf (D1)               │
│      ├─ Outline — outline write via lopdf Bookmark/Outline          │
│      └─ AcroForm — /AP generation, /AcroForm re-attach              │
│    Render   → PDFium NIF  (dirty-scheduled)                         │
│    Ocr      → Tesseract NIF + vix NIF (preprocess)                  │
│    Office   → native OOXML/ODF reader & writers (over `:zip`+`Saxy`)│
│    Html     → chromic_pdf → system Chromium (only external process) │
│    Sign     → Quire.Pades (over Quire.Pdf + OTP crypto)             │
│    Encrypt  → Quire.SecurityHandler (over Quire.Pdf + OTP crypto)   │
└───────────────┬─────────────────────────────────────────────────────┘
                │ Oban
┌───────────────▼─────────────────────────────────────────────────────┐
│ WORKERS (same BEAM node, separate queues — §7.5)                    │
│  :render    thumbnails, page previews         (PDFium NIF)          │
│  :convert   Office↔PDF, image, HTML, TXT, RTF (Office.*, chromic)   │
│  :transform merge/split/compress/crop/stamp   (PDFium NIF, Compose) │
│  :ocr       Tesseract NIF pipeline            (optionally 2nd node) │
│  :secure    encrypt, redact, sanitize, sign   (Pades, SecHandler)   │
│  :esign     envelope mail, reminders                              │
│  :translate MT/LLM provider calls             (HTTP)                │
│  :batch     recipe runner over N files        (chains the above)    │
│  :maintenance  revision + scratch retention                         │
└─────────────────────────────────────────────────────────────────────┘

Everything above runs on one MacBook, in one BEAM node, against one locally
installed PostgreSQL 18. The only non-BEAM collaborators are PostgreSQL and
an on-demand Chromium process for HTML rendering. There are no resident
helper services, no other interpreters, no CLI tools.
```

### 4.1 The hybrid boundary — which side does what

This table is the single most important design artefact in the plan. When
implementing a feature, look it up here first.

| Operation class | Where | Rationale |
|---|---|---|
| Scroll, zoom, page render, text selection, search | **Client** | Must be instant. pdf.js virtualised viewer. |
| Highlight / underline / strikethrough / sticky note / ink / free text / stamp | **Client**, mirrored to journal | pdf.js `AnnotationEditorLayer`; server never blocks the stroke. |
| Form field *filling* | **Client** | pdf.js `annotationStorage` + `saveDocument()`. |
| Form field *creation* | **Client** geometry, **server** commit | Placement is interactive; writing the AcroForm dict is a mutation. |
| Signature/initials placement | **Client** placement, **server** flatten | Visual placement is interactive; PAdES signing is server-only (private keys never touch the browser). |
| Page insert/delete/rotate/reorder/extract | **Client** preview, **server** authoritative | Optimistic thumbnail reorder, the PDFium NIF does the real work via page import. |
| Merge, split, compress, crop, watermark, header/footer, Bates | **Server** | PDFium NIF page import + page objects, vix for image recompression. |
| Encrypt / decrypt / permissions | **Server** | Never expose passwords to client JS. Pure-Elixir security handler. |
| Redaction | **Server** | True content removal must be authoritative and verifiable. |
| OCR | **Server** | Tesseract NIF. |
| Office ↔ PDF, PDF → HTML/TXT/RTF, PDF/A | **Server** | Native OOXML layer / chromic_pdf / PDFium+PdfA. |
| Digital signature, e-sign envelopes | **Server** | `Quire.Pades`. |
| Translate | **Server** | Provider API keys stay server-side; never expose them to a hook. |

**Rule of thumb:** if the user expects sub-100 ms feedback, it is client-side
and journaled; if it produces a new file, it is server-side and creates a
revision.

---

## 5. Data model

Ecto schemas, PostgreSQL 18. All IDs are `binary_id` holding **UUID v7** —
generated Elixir-side with `Uniq.UUID.uuid7/0`, with `DEFAULT uuidv7()` on
the column as a backstop (§3.7). Time-ordered keys keep inserts on the
right-hand edge of the B-tree, which is what the append-only
`document_revisions` and `edit_operations` tables need.

**No extensions.** Every migration must run against a stock
`brew install postgresql@18` with no `CREATE EXTENSION` line anywhere. If a
schema seems to need one, the design took a wrong turn — say so in review
rather than adding it.

### 5.1 Core

```
users                      -- phx.gen.auth, created in Phase 0 by T-200 (NOT T-006)
  id, email, hashed_password, confirmed_at, inserted_at, updated_at
  -- email is :string with a lower(email) unique index, not citext (§3.4)

users_tokens               -- phx.gen.auth, same migration as users
  id, user_id, token, context, sent_to, authenticated_at, inserted_at

user_settings
  id, user_id, theme, default_zoom, default_view_mode, ruler_visible,
  grid_visible, qat_items (jsonb array), recent_limit, ocr_default_lang,
  measurement_unit, autosave_enabled, inserted_at, updated_at

licenses
  id, user_id, tier (:trial | :standard | :premium | :business),
  seats, activated_at, expires_at, activation_key, inserted_at, updated_at
```

`licenses` exists because the reference UI has an `Activate now` button and
gated features. §11.2 lists what each tier unlocks.

### 5.2 Documents and revisions

```
documents
  id, owner_id, title, source (:upload | :url | :scan | :clipboard |
    :created | :cloud), origin_metadata (jsonb), page_count,
  current_revision_id, encrypted boolean, has_forms boolean,
  has_signatures boolean, is_tagged boolean, deleted_at,
  inserted_at, updated_at

document_revisions              -- append-only, content-addressed
  id, document_id, parent_revision_id, seq integer,
  storage_ref (jsonb — an opaque Storage ref, §7.1), byte_size,
  sha256, page_count, produced_by (:upload | :client_save | :job),
  job_id, operation_summary (jsonb), inserted_at

document_pages                  -- denormalised page geometry cache
  id, revision_id, index integer, width_pt, height_pt, rotation integer,
  has_text boolean, thumbnail_ref (jsonb), inserted_at

document_page_text              -- server-side search fallback (PG18)
  id, revision_id, page_index integer, content text,
  search tsvector GENERATED ALWAYS AS (to_tsvector('simple', content)) STORED,
  spans (jsonb — per-span bboxes from Render.extract_text), inserted_at
  -- GIN index on `search`. STORED, not VIRTUAL: virtual generated columns
  -- cannot be indexed (§3.7).

recent_documents
  id, user_id, document_id, last_opened_at, pinned boolean
```

`document_page_text` exists because pdf.js's `PDFFindController` searches
only what the client has loaded, which is fine for a 20-page contract and
useless for `500_pages.pdf`. Populate it from the text-layer probe in §10.3
step 5, and have the search panel (T-046) fall back to it above a page-count
threshold. Use `websearch_to_tsquery/2` so the user's quotes and
`-exclusions` work the way they expect. The `'simple'` configuration is
deliberate — no stemming, because a PDF search box is expected to match
literally.

**Why revisions rather than mutating one blob:** every server operation (OCR,
compress, redact, sign) must be undoable, and "Save" vs "Save optimized" vs
"Save as" all need a stable notion of *which bytes*. An append-only revision
chain gives you undo of heavy operations, cheap `Compare` (§9.6), and audit
trails for signed documents. Prune old revisions with a retention job
(T-173).

### 5.3 Editing

```
edit_operations                 -- the undo/redo journal (§7.4)
  id, document_id, revision_id, user_id, seq integer,
  kind (see §7.4 op catalogue), payload (jsonb), inverse (jsonb),
  applied_side (:client | :server), undone boolean, inserted_at

annotations
  id, document_id, page_index, kind (:highlight | :underline |
    :strikethrough | :squiggly | :sticky_note | :free_text | :ink |
    :stamp | :line | :arrow | :rectangle | :oval | :polygon |
    :attachment | :whiteout | :redaction_mark),
  rect (jsonb {x,y,w,h} in PDF points), quad_points (jsonb),
  path_data (jsonb), contents text, author, color, opacity,
  border_width, flags (jsonb), pdf_object_ref, replies_count,
  inserted_at, updated_at

annotation_replies
  id, annotation_id, user_id, body, inserted_at

text_edits                      -- Edit tab content changes
  id, document_id, page_index, kind (:add_text | :edit_text |
    :insert_image | :link | :page_number | :watermark |
    :header_footer | :bates), rect, style (jsonb), content (jsonb),
  applied_revision_id, inserted_at
```

### 5.4 Forms, security, signing

```
form_fields
  id, document_id, page_index, name, kind (:text | :combo | :list |
    :checkbox | :radio | :button | :signature),
  rect, required boolean, read_only boolean, default_value,
  options (jsonb), validation (jsonb), tab_order integer,
  appearance (jsonb)

form_submissions
  id, document_id, user_id, values (jsonb), submitted_at

security_policies
  id, document_id, user_password_set boolean, owner_password_set boolean,
  key_length (128|256), permissions (jsonb — print, modify, copy,
  annotate, fill_forms, extract_a11y, assemble, print_hq),
  applied_revision_id, inserted_at

redactions
  id, document_id, page_index, rect, reason_code, overlay_text,
  applied boolean, applied_revision_id, inserted_at

digital_signatures
  id, document_id, revision_id, signer_name, signer_email,
  certificate_subject, certificate_issuer, serial, signed_at,
  tsa_url, pades_level (:b_b | :b_t | :b_lt),
  field_name, validation_status (jsonb), inserted_at

esign_envelopes
  id, document_id, owner_id, subject, message,
  status (:draft | :sent | :partially_signed | :completed |
    :declined | :voided | :expired),
  expires_at, sent_at, completed_at

esign_signers
  id, envelope_id, name, email, order integer, role,
  status (:pending | :viewed | :signed | :declined),
  access_token, signed_at, ip_address, user_agent

esign_fields
  id, envelope_id, signer_id, page_index, rect,
  kind (:signature | :initials | :name | :date | :text | :checkbox),
  required boolean, value

esign_audit_events
  id, envelope_id, signer_id, event, metadata (jsonb), occurred_at
```

`esign_audit_events` is not optional — an e-signature without a defensible
audit trail is not an e-signature.

### 5.5 Jobs, OCR, translation

```
operations                      -- user-visible job status (drives progress UI)
  id, document_id, user_id, kind, status (:queued | :running |
    :succeeded | :failed | :cancelled), progress integer,
  input (jsonb), result (jsonb), error (jsonb),
  oban_job_id, started_at, finished_at, inserted_at

ocr_results
  id, document_id, revision_id, languages (array), engine_version,
  page_confidences (jsonb), searchable boolean, inserted_at

translations
  id, document_id, source_lang, target_lang, mode (:overlay | :sidecar |
    :replace), result_revision_id, glossary (jsonb), inserted_at

translation_cache               -- keyed by sha256(text)+langs, §9.11
  id, key (unique), source_lang, target_lang, output text,
  provider, token_usage (jsonb), inserted_at

batch_jobs                      -- the Home "Batch" tile
  id, user_id, recipe (jsonb — ordered list of ops),
  status, total, completed, failed, inserted_at
```

### 5.6 Cloud connections

```
cloud_connections               -- backstage "Add account"
  id, user_id, provider (:google_drive | :dropbox | :onedrive | :box |
    :s3 | :webdav), display_name, access_token_encrypted,
  refresh_token_encrypted, expires_at, scopes, inserted_at
```

Tokens MUST be encrypted at rest (`cloak_ecto` or equivalent).

---

## 6. Module tree

```
lib/quire/
  application.ex
  repo.ex

  storage.ex                    # behaviour (§7.1)
  storage/ref.ex
  storage/web.ex                # dispatches to a backend
  storage/web/filesystem.ex     # the only backend built in v1
  storage/web/s3.ex             # stub — raises; keeps the seam honest
  storage/local.ex

  engine.ex                     # engine registry + boot self-check (§7.2)
  render.ex                     # behaviour (§7.3)
  render/pdfium.ex              # primary: ex_pdfium NIF
  render/client.ex              # fallback: browser pdf.js renders thumbnails
  ocr/engine.ex                 # behaviour + pipeline orchestration
  ocr/tesseract.ex              # Tesseract NIF wrapper
  ocr/preprocess.ex             # deskew/denoise via vix
  office/reader.ex              # OOXML/ODF → layout model (pure Elixir)
  office/layout.ex              # intermediate layout model → HTML
  office/writer/docx.ex         # PDF content → .docx (pure Elixir)
  office/writer/xlsx.ex         # PDF content → .xlsx (elixlsx or native)
  office/writer/pptx.ex         # PDF content → .pptx (pure Elixir)
  office/writer/rtf.ex          # PDF content → .rtf (pure Elixir)
  pades.ex                      # PAdES signing + validation (over Quire.Pdf + OTP crypto)
  pades/cms.ex                  # CMS/PKCS#7 over :public_key
  pades/pkcs12.ex               # keystore parsing
  pades/tsa.ex                  # RFC 3161 client over Req
  security_handler.ex           # AESV2/AESV3 encryption (over Quire.Pdf + OTP :crypto)
  pdf.ex                        # Rustler NIF over lopdf 0.44.0: load/save, catalog & dict mutation, IncrementalDocument, save_modern, authenticate_password, Bookmark/Outline
  pdf/outline.ex                # outline write via lopdf Bookmark/Outline (D2)
  pdf/acro_form.ex              # /AP generation, /AcroForm re-attach after page import (D5)
  pdf_a.ex                      # best-effort PDF/A + conformance report
  compose.ex                    # content-stream **and /AP appearance-stream** generation, over Quire.Pdf

  documents.ex                  # context: CRUD, revisions, recents
  documents/document.ex
  documents/revision.ex
  documents/page.ex
  documents/recent.ex

  editing.ex                    # context: journal, undo/redo
  editing/edit_session.ex       # GenServer (§7.4)
  editing/edit_session_supervisor.ex
  editing/operation.ex
  editing/ops/*.ex              # one module per op kind

  annotations.ex
  forms.ex
  security.ex
  conversion.ex
  ocr.ex
  signing.ex
  esign.ex
  translation.ex
  batch.ex

  accounts.ex                   # phx.gen.auth (T-200)
  accounts/user.ex              # phx.gen.auth
  accounts/user_token.ex        # phx.gen.auth
  accounts/user_notifier.ex     # phx.gen.auth
  accounts/scope.ex             # phx.gen.auth — the `current_scope` struct
  licensing.ex
  cloud.ex

  workers/
    render_worker.ex
    convert_worker.ex
    transform_worker.ex
    ocr_worker.ex
    secure_worker.ex
    sign_worker.ex
    esign_worker.ex
    translate_worker.ex
    batch_worker.ex
    retention_worker.ex

lib/quire_web/
  endpoint.ex
  router.ex
  telemetry.ex
  user_auth.ex                  # phx.gen.auth (T-200) — plugs + on_mount

  components/
    core_components.ex          # generated, trimmed
    chrome/
      title_bar.ex              # §8.2
      quick_access_toolbar.ex
      menu_bar.ex
      ribbon.ex                 # §8.3 — the ribbon primitives
      ribbon_button.ex
      ribbon_split_button.ex
      ribbon_group.ex
      status_bar.ex
      document_tabs.ex
      side_rail.ex
    panels/
      thumbnails_panel.ex
      bookmarks_panel.ex
      search_panel.ex
      attachments_panel.ex
      comments_panel.ex
      layers_panel.ex
      signatures_panel.ex
    floating/
      text_format_bar.ex        # §9.5
      fill_sign_palette.ex      # §9.4
      annotation_props_bar.ex
    dialogs/
      add_action_dialog.ex      # §9.5
      properties_dialog.ex
      print_dialog.ex
      security_dialog.ex
      ...

  live/
    home_live.ex                # §10.1
    backstage_live.ex           # §10.2 (a component of workspace)
    workspace_live.ex           # §8.1 — the shell
    workspace_live/
      document_component.ex
      tabs/
        view_tab.ex
        create_convert_tab.ex
        fill_sign_tab.ex
        edit_tab.ex
        page_tab.ex
        comment_tab.ex
        secure_tab.ex
        forms_tab.ex
        esign_tab.ex
        ocr_tab.ex
        translate_tab.ex
    esign/
      sign_live.ex              # public signer-facing route
    settings_live.ex
    user_live/                  # phx.gen.auth (T-200)
      registration.ex
      login.ex
      confirmation.ex
      settings.ex

  controllers/
    document_controller.ex      # range-request byte serving, downloads
    esign_controller.ex
    health_controller.ex
    user_session_controller.ex  # phx.gen.auth (T-200)

native/
  quire_pdf/                    # Rustler crate over lopdf 0.44.0, compiled from source (Rust ≥ 1.91, ADR 0003 D1, ADR 0004). Mark every NIF DirtyCpu.
    Cargo.toml
    src/lib.rs

assets/js/
  app.js
  hooks/
    pdf_viewer.js
    annotation_editor.js
    doc_mutate.js
    opfs_cache.js
    ruler_grid.js
    thumbnail_dnd.js
    signature_pad.js
    read_aloud.js
  pdf/
    engine.js                   # thin facade over pdf.js
    mutate.js                   # thin facade over @cantoo/pdf-lib
    geometry.js                 # PDF points ↔ CSS px, viewport math
```

**Naming rule:** contexts are nouns (`Documents`), workers are verbs
(`ConvertWorker`), LiveComponents end in `Component`, function components are
plain. Every ribbon tab is a `Phoenix.LiveComponent` so it can hold tool
state without bloating the parent socket.

---

## 7. Core abstractions

These five modules are the load-bearing walls. Build them in Phase 0, before
any feature work, and do not let feature code route around them.

### 7.1 `Quire.Storage` — the filesystem boundary

The single decision that determines whether the desktop build (§12) is a
config change or a six-week rewrite.

The behaviour's callbacks (all callers see opaque refs, never paths):

- `put/2`, `get/1`, `stream/2`, `delete/1`, `size/1`, `name/1`
- `with_local_path/2`, `with_local_paths/2`, `with_scratch_dir/1` —
  materialise a ref into a real path for code that needs one (a NIF that
  takes a file path, or Chromium), then clean up. **The only sanctioned way
  to obtain a filesystem path.**
- `pick_open/1`, `pick_save/1`, `list_dir/1` — desktop-only; the Web adapter
  returns `{:error, :unsupported}` and callers fall back to LiveView uploads
  / `send_download/3`.

Dispatch is by **runtime lookup** (`Application.fetch_env!(:quire,
:storage_adapter)`), never compile-time — `defdelegate` would bake the
adapter into the release and destroy the web-vs-desktop swap that all of §12
depends on.

`Storage.Ref` is an opaque struct: `adapter`, `key`, `name`, optional
`content_type`, `byte_size`, `meta`.

**Rules:**

- `Ref.key` is meaningless to callers. In the Web adapter's filesystem
  backend it is a content-addressed relative path under the data root; in a
  future S3 backend it would be an object key; in the Local adapter it is an
  absolute path. **Nothing outside the adapter may inspect it.**
  Specifically: do not derive a filename from it for a download header —
  that is what `Ref.name` is for.
- `%Plug.Upload{}` never crosses a context boundary.
  `consume_uploaded_entry/3` immediately produces a `Ref`.
- Every engine invocation that needs a path uses `with_local_path/2` or
  `with_scratch_dir/1`, which create a per-operation temp directory and
  remove it in an `after` block, even on crash.

**`Storage.Web`** — dispatches to a **backend** chosen by
`config :quire, :storage_backend`.

- **`:filesystem`** (the only backend built in v1). Root defaults to
  `<repo>/_data/storage`, overridable with `QUIRE_DATA_DIR`. Keys are
  `<first2>/<next2>/<uuid>` two-level fan-out — flat directories with 100k
  files make `ls`, Finder and Spotlight miserable. Writes go to a temp file
  in the same directory and are `File.rename/2`'d into place, so a crash
  mid-write never leaves a half-written ref that something later reads as a
  valid PDF. `with_local_path/2` is the cheap case here: the file already
  *is* a local path, so it hands over the real path and skips the copy. Do
  not let that optimisation leak — callers must still treat the path as
  valid only inside the function.
- **`:s3`** — a stub module that raises with a pointer to this section, plus
  the shared `StorageCase` suite tagged `@tag :skip`. It exists so the seam
  is visible and so adding S3 later is filling in a module rather than
  discovering that six months of code assumed a real path.

**`Storage.Local`** — plain `File.*`. `pick_open`/`pick_save` push a request
to the client, which calls the desktop shell's native dialog and returns a
real path over a LiveView event.

**Deliberately not used: the File System Access API.** `showOpenFilePicker`
and friends are Chromium-only — unsupported in Firefox and Safari, and
WebKit's standards position is formally **oppose**. Worse, Tauri uses
WKWebView on macOS and webkit2gtk on Linux, so a web app built around FSA
**breaks on two of three desktop platforms**. Every line written against it
is a line rewritten at packaging time.

**OPFS (`navigator.storage.getDirectory()`) is different and IS used** — it
is Baseline since March 2023 and gives a fast origin-private scratch layer
for caching the working PDF so scroll and undo don't re-fetch. It is
invisible to the user and quota-bound, so it is a cache, never a source of
truth. See T-033.

### 7.2 `Quire.Engine` — the capability boundary

Because the engine layer is in-BEAM (§3.3), there is no `PATH` resolution
problem and no CLI runner. The boundary that replaces them is a registry of
engine behaviours plus a boot-time self-check, and its rules are about
scheduler safety, input limits and isolation rather than subprocesses.

Every engine module behind a behaviour:

- `Quire.Render` (§7.3) — PDFium NIF primary, client-side fallback.
- **`Quire.Pdf` — Rustler NIF over `lopdf` 0.44.0; the PDF object model.**
  Everything below that writes raw PDF structure goes through it, so the
  dirty-scheduler and bounded-input rules in this section apply to it in full.
  Unlike `ex_pdfium` and `vix` it is **compiled from source on every
  `mix compile`**, which is why Rust ≥ 1.91 is a hard prerequisite (§3.1) and
  why its NIFs are ours to mark `DirtyCpu` — nobody upstream did it for us.
  Sub-modules: `Quire.Pdf.Outline` (outline write) and `Quire.Pdf.AcroForm`
  (`/AP` generation, `/AcroForm` re-attach after page import).
- `Quire.Ocr.Engine` — `image_ocr` NIF, with vix preprocessing.
- `Quire.Office.Reader` / `Office.Writer.*` — pure Elixir.
- `Quire.Pades` — signing/validation, over `Quire.Pdf` for structure writes.
- `Quire.SecurityHandler` — encryption, over `Quire.Pdf` for `/Encrypt`.
- `Quire.PdfA` — best-effort PDF/A + conformance report, over `Quire.Pdf`.
- `Quire.Compose` — content-stream **and `/AP` appearance-stream** generation,
  over `Quire.Pdf`. Not "pure Elixir": its foundation is a NIF.

**Rules every engine call MUST follow:**

- **Dirty schedulers only for NIF work.** Any NIF invocation expected to
  exceed ~1 ms must be declared `DirtyCpu`/`DirtyIo` in the wrapper. T-021
  and T-022 prove this per NIF; `mise run doctor` re-asserts it.
- **Serialisation is a separate property from scheduling, and PDFium has
  it.** Dirty scheduling keeps the BEAM responsive; it does **not** make an
  engine parallel. `ex_pdfium` serialises every call behind one process-wide
  mutex (§3.3), so its effective parallelism is 1 no matter how wide the
  queue. Any engine wrapper over a globally-locked native library MUST
  declare that limit here and have §7.5 size its queue to it, rather than
  letting the queue imply a concurrency the engine cannot deliver.
- **Bounded inputs.** Workers enforce size and page-count caps before calling
  a NIF (a 4 GB malformed PDF must be rejected by policy, not by a NIF
  crash).
- **Job-level timeouts.** Oban jobs carry per-kind time limits; a stuck NIF
  call is abandoned by the job and surfaced as a structured error. (A truly
  wedged NIF cannot be killed mid-call — this is why input bounds and the
  corpus fuzz pass exist, and why `:ocr` MAY run on a second BEAM node,
  §3.3.)
- **Telemetry.** Every engine call emits `:telemetry` events
  `[:quire, :engine, :start | :stop | :exception]` with `engine`,
  `operation`, `duration`.
- **Structured errors.** Engine errors map to user-facing messages, never
  raw NIF error atoms.
- **No `System.cmd` anywhere** except inside `chromic_pdf`'s own Chromium
  management, which is the single sanctioned external process.

**Boot self-check (T-013).** At boot, `Quire.Engine.check/0`:

- loads each NIF and calls its version/info function;
- runs one tiny fixture (a 1-page PDF, a 1-line image) through Render and
  OCR end-to-end — this is both a smoke test and a crash-fuzz canary;
- resolves the Chromium executable from config (feature degrades cleanly if
  absent);
- captures every component version into `Quire.Engine.versions/0`,
  surfaced in Settings → About (PDFium build — **144.0.7543.0**, whatever
  `ex_pdfium 0.5.1` bundles; `lopdf` version behind `Quire.Pdf`; Tesseract
  and Leptonica versions; libvips version **and its LGPL-3.0-or-later
  notice**, §12.1 step 9; Chromium version, OTP/Elixir versions, Postgres
  version);
- reports one of three states per capability and prints a table at boot:

| State | Meaning | Effect |
|---|---|---|
| `ok` | Engine loaded, self-test passed | Feature enabled |
| `degraded` | Engine loaded, self-test flaky or version drifted | Feature enabled, loud warning |
| `unavailable` | Engine failed to load (or Chromium not found) | Feature disabled with a message naming the remedy |

The same check backs `mise run doctor`, which runs it via
`mix run --no-start` and exits non-zero on anything worse than `ok`. Without
a container image to assert against at build time, this is the whole of the
reproducibility guarantee — treat a red doctor as a broken build.

### 7.3 `Quire.Render` — rasterisation & extraction

Callbacks (all take and return plain data; refs via §7.1):

- `page_count/1`, `page_geometry/1`
- `render_page/3` → PNG bytes
- `thumbnails/2` → list of PNG bytes
- `extract_text/2` → per-page text with spans (per-span bboxes)
- `search/3` → page + rect + context hits
- `form_fields/1`, `annotations/1`
- `extract_images/2` → embedded rasters at native resolution (§9.3)
- `outline/1` → bookmark tree (§9.1). **Read only** — outline *write* is
  `Quire.Pdf.Outline`, because PDFium's public API has no bookmark setter at
  all (§3.3)
- `import_pages/…`, `new_document/…`, `add_page_objects/…`, `save/…` — the
  mutation surface used by Page ops, Merge/Split, stamping and redaction.
  `save/…` produces **no linearization**; where output structure matters
  (Compress, PDF/A, incremental signing) the writer is `Quire.Pdf`
- Two callbacks this behaviour must *not* grow, because no PDFium build
  answers them: linearizing save, and any bookmark mutation. Route them to
  `Quire.Pdf` instead of adding an `unavailable` state for them

Primary implementation `Render.Pdfium` wraps `ex_pdfium` 0.5.1, pinned
exactly (`== 0.5.1`, not `~> 0.5.1`). **T-021 gates the NIF: prove it runs
on dirty CPU schedulers before it touches a request path.** Rendering a page
will exceed the 1 ms NIF budget; if it schedules on a normal scheduler it
will stall the BEAM under load and you will chase mysterious latency for a
week. If it stalls, patch it (`#[rustler::nif(schedule = "DirtyCpu")]` and
vendor the fork) — the MIT licence makes this painless.

**Fallback `Render.Client`.** If the NIF is unavailable, thumbnail and
preview rendering degrades to the browser: pdf.js already renders every page
the user looks at, so the viewer hook captures downscaled canvas PNGs and
uploads them. This is slower and only covers pages actually viewed, which is
fine for a degraded mode — and it keeps *reading* fully functional even with
the NIF gone. Server-authoritative text extraction has no client substitute;
`extract_text` simply reports `unavailable` and text-dependent features
degrade per §7.2.

**Apple Silicon check, before T-018 not during it:** `ex_pdfium` uses
`rustler_precompiled`, so it only avoids a Rust build if an
`aarch64-apple-darwin` artefact was published for the exact version pinned.
Compile the dep on a clean `_build` as the very first thing in Phase 0 and
watch whether it downloads or compiles. If it compiles, that is fine — mise
already provides the Rust toolchain — but it means every clean build costs
minutes. Record the outcome in the same ADR as T-021.

Thumbnails are always produced in the `:render` Oban queue, never inline.

### 7.4 `Quire.Editing.EditSession` — undo/redo across the hybrid boundary

The window chrome has undo and redo buttons that must work across *both*
client-side annotation edits and server-side transformations. This is the
hardest design problem in the project; get it right in Phase 0.

**Model.** One `EditSession` GenServer per open document, under a
`DynamicSupervisor` with a `Registry` keyed by `{document_id, user_id}`. It
holds: `document_id`, `base_revision_id` (last persisted revision),
`journal` (applied ops, newest first), `redo_stack`, `dirty?`, `subscribers`.

**Operation catalogue** (`kind` values in `edit_operations`):

| Group | Kinds |
|---|---|
| Annotation | `annot.add`, `annot.update`, `annot.delete`, `annot.reply` |
| Text/content | `text.add`, `text.edit`, `text.style`, `image.insert`, `link.add`, `link.edit` |
| Page marks | `mark.page_number`, `mark.watermark`, `mark.header_footer`, `mark.bates`, `mark.remove` |
| Page structure | `page.insert`, `page.delete`, `page.move`, `page.rotate`, `page.replace`, `page.crop`, `page.size`, `page.margin`, `page.background`, `page.reverse` |
| Forms | `form.add_field`, `form.update_field`, `form.delete_field`, `form.fill` |
| Security | `sec.encrypt`, `sec.permissions`, `sec.redact_mark`, `sec.redact_apply`, `sec.sanitize`, `sec.strip_metadata` |
| Document | `doc.merge`, `doc.split`, `doc.compress`, `doc.ocr`, `doc.convert`, `doc.sign`, `doc.metadata`, `doc.bookmark_add`, `doc.bookmark_update`, `doc.bookmark_delete`, `doc.bookmark_move` |

Every operation MUST carry an `inverse` payload sufficient to undo it without
consulting anything else. For client-side ops the inverse is the prior state
(cheap). For server-side ops the inverse is `{:restore_revision,
revision_id}` — which is why the revision chain in §5.2 exists.

**Capture the inverse in the same statement as the mutation.** For
update-shaped ops (`annot.update`, `form.update_field`, `text.edit`,
`doc.metadata`), PG18's `RETURNING` can reference both `OLD.*` and `NEW.*`,
so the prior state and the new state come back from one `UPDATE`. Doing it
in one statement removes a class of "undo restored the wrong text" bugs that
only appear under concurrent edits — which, on a single-user laptop, you will
not reproduce until much later.

**Flow — client-side op:**

1. Hook applies the change in pdf.js immediately (optimistic).
2. Hook pushes the op to the LiveView.
3. LiveView calls `Editing.apply(session, op)` → validated, persisted to
   `edit_operations`, prepended to the journal, broadcast on PubSub.
4. Nothing round-trips back to the originating client unless validation
   failed, in which case the LiveView pushes a `revert` event.

**Flow — server-side op:**

1. LiveView calls `Editing.apply(session, op)` with `applied_side: :server`.
2. An `operations` row is created (status `:queued`) and an Oban job
   enqueued.
3. Worker runs, produces a new `document_revisions` row, updates
   `documents.current_revision_id`, broadcasts `{:revision, rev}`.
4. LiveView pushes the new revision URL to the viewer hook, which reloads.
5. The journal entry's `inverse` is `{:restore_revision, previous_id}`.

**Undo** pops the journal head, applies its inverse (client-side: push a
`revert` event to the hook; server-side: point
`documents.current_revision_id` back), and pushes onto `redo_stack`. Any new
op clears `redo_stack`.

**Coalescing.** Consecutive `text.style` or `annot.update` ops on the same
target within 800 ms MUST coalesce into one journal entry, or undo becomes
useless during typing.

**Save.** `Save` materialises the journal into a new revision: client-side
ops are already reflected in the bytes the hook holds (via
`PDFDocumentProxy.saveDocument()` / `@cantoo/pdf-lib`), so `Save` uploads
those bytes and creates a revision. `Save optimized` runs the same, then a
compress job. `Save as` creates a new `documents` row.

**Session lifecycle.** Hibernate after 5 min idle, terminate after 30 min,
persisting the journal. Reopening rehydrates from `edit_operations`.

### 7.5 Oban queues and progress

**Sized for a laptop, not a server.** On a MacBook you are also running a
browser, an editor and a language server, and the queues below are the
difference between "OCR is running" and "the fan is at maximum and the UI has
stopped responding".

Every queue limit in the table below is a **literal constant** — none is
derived from CPU count. The rationale for each is specific to its engine and
the resource it consumes, not to hardware. In particular `render` and
`transform` are fixed at 1 because `ex_pdfium` serialises every call behind a
process-wide `PDFIUM_LOCK` (§3.3: 44 of 45 NIFs acquire it, so effective
parallelism is **1**). A core-derived width there would buy contention and a
second full copy of each document in native memory per blocked worker, and no
throughput.

| Queue | Concurrency | Why |
|---|---|---|
| `render` | **1 — fixed, not derived** | PDFium NIF. All 45 NIFs are correctly `DirtyCpu`, so the BEAM stays responsive, but every call serialises behind `PDFIUM_LOCK`. Raise this only if the D4 fork ships per-document locks *and* PDFium is proven thread-safe per-instance |
| `transform` | **1 — fixed, not derived** | Same lock. PDFium page ops contend with `render` on it, so the two queues share one effective slot between them |
| `convert` | 1 | Chromium instances are heavyweight; one at a time. The OOXML writers are pure Elixir but run in this queue for pacing |
| `ocr` | 1 | Tesseract already parallelises internally; MAY move to a second BEAM node (§3.3) |
| `secure` | 2 | Signing/encryption are pure-Elixir crypto — cheap, but keep I/O ordering sane |
| `esign` | 2 | Mail-bound |
| `translate` | 2 | Network-bound; concurrency is about provider rate limits |
| `batch` | 1 | Chains the above |
| `maintenance` | 1 | Retention |

Oban plugins: Pruner (7 days), Lifeline (30 min rescue), Reindexer.

⚠️ **`convert: 1` is about Chromium, not conservatism.** Each HTML→PDF job
spawns a browser tab context with real memory cost; two concurrent ones on a
laptop produce swap pressure that reads as a random timeout. If you need
parallel conversion later, pool browser instances explicitly with a hard
instance cap — do not just raise this number.

⚠️ **`ocr: 1` and `render: 1` interact.** Tesseract spawns its own threads
and the PDFium NIF occupies dirty CPU schedulers. Running both flat out
starves the normal schedulers that LiveView needs to send diffs, and the
symptom is a UI that freezes only during OCR — which reads as a LiveView
bug. T-189's load test exists to catch exactly this on your actual hardware;
treat the numbers above as a starting point and tune them there — but note
that `render` and `transform` are the two numbers T-189 **cannot** tune
upward, because the ceiling is a mutex and not the machine.

⚠️ **Raising a PDFium queue costs memory before it costs anything else.**
`ExPdfium.open/2` (via the private `document_open/2` NIF) copies the whole file into a native buffer
(`decode_source` → `bytes.as_slice().to_vec()`) **before** it enters
`with_pdfium`, which is where the lock is taken. So every worker queued
behind the mutex is already holding a second full copy of its document in
native memory while doing no work at all. Four `render` workers on 50 MB
documents pin ~200 MB of native buffers to achieve the throughput of one.
This is the concrete reason the fix for slow rendering is the D4 fork or a
second BEAM node (§3.3), never a bigger number in this table.

Every worker MUST:

- write progress to the `operations` row and broadcast
  `{:operation_progress, id, pct}` on `PubSub` topic `"document:#{doc_id}"`;
- be idempotent — Oban retries, and a half-written revision is worse than a
  failed one. Write output to a scratch ref, then atomically insert the
  revision row;
- set explicit `max_attempts` (conversion 3, OCR 2, sign 1 — never silently
  re-sign);
- attach `unique: [period: 60, fields: [:worker, :args]]` for
  render/thumbnail jobs to avoid stampedes.

The UI surface for this is a status strip + a toast (§8.6), driven entirely
by those PubSub messages.

---

## 8. UI system

### 8.1 Shell composition

```
WorkspaceLive  (single LiveView, owns everything)
├── TitleBar               logo · QAT · title · account · window controls
├── MenuBar                hamburger · home · 11 tabs · Activate · help · gear
├── Ribbon                 renders the active tab's LiveComponent
├── DocumentTabs           one chip per open document + close buttons
├── Body
│   ├── LeftRail           panel toggle · bookmarks
│   ├── LeftPanel          (collapsible) thumbnails | bookmarks | comments | signatures | layers
│   ├── DocumentComponent  the pdf.js canvas host + floating toolbars
│   ├── RightPanel         (collapsible) search | attachments | properties
│   └── RightRail          search · attachments
└── StatusBar              page nav · zoom · operation progress
```

`WorkspaceLive` is one LiveView, not several. The ribbon, tabs and document
must stay in lockstep, and splitting them across LiveViews means every
interaction becomes a PubSub round trip. Keep per-tab state inside the tab's
LiveComponent so the parent socket stays small.

**Backstage** (§10.2) is rendered as a full-screen overlay component inside
`WorkspaceLive`, matching the reference where the File menu covers the window
and has a back arrow.

**Home** (§10.1) is a separate `HomeLive` at `/`, because it has no document
context. The home icon in the menu bar navigates there; opening a document
navigates to `/workspace/:id`.

### 8.2 Chrome specification

Measured against the reference screenshots. The reference window is 1920 px
wide; treat these as design tokens, not hardcoded pixels.

**Title bar** — 60 px tall, white. Left: 44×44 brand square (accent colour,
rounded 8 px) then a 24 px-icon row: undo, redo, open, save, print, email,
`+` new, chevron (QAT customise menu). Centre: document title, 15 px, medium
weight, format `{title} - {AppName}`. Right: account avatar (with a 6 px
accent dot when notifications pending), minimise, maximise/restore, close.
In the **web** build the three window buttons are hidden; in the **desktop**
build they call the shell (§12).

The **email** QAT button opens a compose modal that attaches the current
revision (as-is, flattened, or as a link) and sends via Swoosh. The **share**
control in the workspace top-right creates an expiring, optionally
password-protected view/comment link, with a revocation list in Settings.
Both are small but they are in the reference chrome, so they are in scope
(T-198).

**Menu bar** — 44 px tall, white, 1 px bottom border `#E5E7EB`. Left:
hamburger (opens backstage), home icon, then tab labels at 14 px with 16 px
horizontal padding. The **active tab** is marked by a 6 px accent dot to the
left of the label plus accent-coloured text — not an underline. When a tab
is "open" but not active (hover/focus) it gets a light grey pill background.
Right: `Activate now` — black pill, white 13 px text, 12/20 px padding, 6 px
radius — then help `?` and settings gear.

**Ribbon** — 84 px tall, white, 1 px bottom border. Buttons are vertical
stacks: 24 px icon over an 11–12 px label, min-width 64 px, 8 px horizontal
gap, centre-aligned. Groups separated by a 1 px × 44 px vertical rule with
16 px margins. A button with a dropdown shows a 10 px chevron to the right
of the label. Disabled buttons render at 38 % opacity and are
`aria-disabled`. The **active tool** gets a light accent-tinted rounded
background. Right-aligned on most tabs: zoom `−`, a percentage combo, `+`.

The Edit / Comment / Secure / Forms / E-Sign / OCR tabs additionally show a
dark **View toggle pill** left of `Activate now`, which switches the document
between edit and read-only preview. Implement it as a single boolean in
`WorkspaceLive` assigns.

**Document tabs** — 40 px tall. Active tab: white background, accent text, no
bottom border (it merges into the canvas). Inactive: grey text on the ribbon
background. Truncate labels at ~18 characters with an ellipsis and a title
tooltip.

**Rails** — 48 px wide, icon-only, 24 px icons, toggle the adjacent panel.

**Canvas** — `#F3F4F6` background, page centred with an 8 px shadow, 24 px
gutter.

**Page navigation** — bottom-right floating pill: `‹  [n]  / total  ›`,
white, 1 px border, 8 px radius, 12 px shadow. The number is an editable
input.

**Floating action buttons** — bottom-right on Home only: feedback
(thumbs-up) and support (chat), 56 px dark circles, 16 px apart.

### 8.3 Component library

Build these first (T-028 – T-029); every tab consumes them:

- `ribbon_group`, `ribbon_button` (icon, label, optional dropdown chevron,
  active/disabled states, tooltip), `ribbon_split_button`, `ribbon_toggle`,
  `ribbon_separator`, `zoom_control` with presets (50/75/100/125/150/200%).
- `floating_bar`, `dropdown_menu`, `modal`, `panel`, `tool_tile` (Home),
  `doc_card` (Recent), `progress_toast`, `color_picker`, `font_picker`,
  `page_thumb`.

**Accessibility is not deferrable.** Ribbon = `role="toolbar"` with roving
tabindex and arrow-key navigation. Tabs = `role="tablist"`/`tab`/`tabpanel`.
Every icon-only control needs `aria-label`. Modals trap focus and restore it
on close. Test with keyboard only at the end of every phase.

### 8.4 Icons and theming

Heroicons (MIT, already wired into Phoenix 1.8) for ~80 % of glyphs; Lucide
(ISC) for the rest (page-crop, bates, whiteout, redaction). **Do not trace
the reference icons.** Define tokens in `assets/css/app.css` (Tailwind v4
`@theme`): an accent colour (pick one, not Soda's red), chrome white, chrome
border `#E5E7EB`, canvas `#F3F4F6`, and the ribbon/titlebar/menubar heights
from §8.2.

Dark mode is a stretch goal (T-188), but write every component with `dark:`
variants from day one — retrofitting is far more expensive.

### 8.5 Keyboard map

MUST be implemented (T-032) — this is a productivity app.

| Shortcut | Action |
|---|---|
| `Ctrl/⌘+O` / `S` / `Shift+S` / `P` | Open / Save / Save as / Print |
| `Ctrl/⌘+Z` / `Shift+Z` / `Y` | Undo / Redo / Redo |
| `Ctrl/⌘+F` / `G` / `Shift+G` | Find / Find next / Find previous |
| `Ctrl/⌘+ +` / `-` / `0` / `1` | Zoom in / out / fit page / actual size |
| `Ctrl/⌘+W` / `Tab` / `Shift+Tab` | Close doc / next doc tab / previous |
| `PageUp` / `PageDown` / `Home` / `End` | Page navigation |
| `Ctrl/⌘+A` | Select all (text or annotations, context-dependent) |
| `Esc` | Cancel active tool, close floating bar or modal |
| `Delete` | Delete selected annotation / page |
| `F11` | Fullscreen |
| `Alt` then letter | Ribbon tab access keys |

### 8.6 Progress, errors, empty states

- Long operations: inline progress in the status bar + a dismissable toast.
  Both driven by `{:operation_progress, id, pct}`.
- Failures: a toast with a plain-language message and a "Details" disclosure
  showing the engine's structured error. Never surface raw engine output as
  the primary message.
- Every panel needs an empty state (no bookmarks, no comments, no
  attachments, no signatures) — the reference app has them and their absence
  reads as broken.

---

## 9. Feature specification — ribbon tabs

Each subsection lists every control from the reference screenshot, what it
does, and how to build it. The **Side** column uses the §4.1 boundary:
**C** = client, **S** = server (Oban job, in-BEAM engine), **C→S** =
interactive on the client, committed on the server.

Subsection order here is **reference order, not build order** — Page is
pulled forward to §9.3 because its plumbing underpins several later tabs, but
otherwise the numbering is arbitrary. **§15 is the authoritative build
order**; when it disagrees with the §9 numbering, §15 wins.

### 9.1 View

*Reference: screenshot 3.*

| Control | Side | Implementation |
|---|---|---|
| **Continuous** ▾ | C | `PDFViewer.scrollMode` / `spreadMode`. Menu: Continuous, Single page, Two pages, Two pages continuous, Cover facing. Persist to `user_settings.default_view_mode`. |
| **Fullscreen** | C | Fullscreen API on the workspace element; hide chrome, show a floating exit affordance. `F11`. |
| **Side by side** | C | Two `PDFViewer` instances in a split pane with synchronised scroll (`scroll` event → set the other's `currentPageNumber`/`scrollTop` ratio). Used by Compare (§9.6). |
| **Fit page** / **Fit width** / **Actual size** | C | `PDFViewer.currentScaleValue = "page-fit" \| "page-width" \| "page-actual"`. Radio-exclusive; the active one gets the tinted background. |
| **Rotate view** | C | `PDFViewer.pagesRotation += 90`. **View-only — does not mutate the document.** Page rotation that persists lives in §9.3. Make the distinction obvious in the tooltip; users conflate them constantly. |
| **Snapshot** | C | Marquee selection → render that region from the page canvas at 2× → copy to clipboard and offer "Save as PNG". |
| **Read aloud** | C | Web Speech API over the page's extracted text layer, with voice/rate/pitch controls, play/pause/stop, and word highlighting via the text layer spans. Degrade with a clear message where unsupported. |
| **Zoom − / % / +** | C | `currentScale`. Steps: 25, 50, 75, 100, 125, 150, 200, 400, 800 %. Combo accepts free entry, clamped 10–1000 %. `Ctrl+scroll` zooms. |

Also in this tab's scope, driven from the rails: **Thumbnails**, **Bookmarks**
(read the PDF outline via the Render behaviour; allow add/rename/delete →
`doc` ops), **Layers** (OCG visibility toggles), **Attachments**,
**Signatures** panels.

**Acceptance:** a 500-page PDF scrolls at 60 fps with no more than 5 canvases
retained; switching view modes preserves the current page; rotate view does
not mark the document dirty.

### 9.2 Create & Convert

*Reference: screenshots 1 and 2.*

All conversions on this tab run in the BEAM (§3.3). Two honesty rules apply
throughout: **state fidelity expectations in the UI** (native Office
conversion is layout-faithful for typical business documents, not for
desktop-publishing layouts), and **every conversion produces an `operations`
row with live progress and a plain-language failure cause**.

| Control | Side | Implementation |
|---|---|---|
| **New** ▾ | C→S | Blank document (size + orientation picker), From template, From clipboard, From scanner. Blank creation is `@cantoo/pdf-lib` `PDFDocument.create()` client-side, then upload as revision 1. |
| **File to PDF** | S | Upload → route by type: **images** (png/jpg/tiff/bmp/webp/heic) → vix normalisation → PDFium new-document + image page objects. **txt/md/csv/html** → render to HTML → chromic_pdf. **docx/xlsx/pptx/odt/ods/odp/rtf** → `Office.Reader` (pure Elixir: unzip, parse the XML, build a layout model) → HTML → chromic_pdf → PDF. Multi-file selection queues one job each. The OOXML reader is the largest single piece of new code in the project — see R-03 and budget Phase 4 accordingly. |
| **Scan to PDF** | C→S | Web build: file input with camera capture plus a WebRTC camera capture LiveComponent with edge detection, deskew (vix) and contrast presets; then image→PDF. OS scanner drivers are out of scope (§1.2). |
| **Clipboard to PDF** | C | `navigator.clipboard.read()` → text or image → `@cantoo/pdf-lib` page. Requires a user gesture and clipboard-read permission; show a paste-target fallback. |
| **URL to PDF** | S | `Req` fetch → chromic_pdf print-to-PDF via the system Chromium. Options: page size, margins, background graphics, header/footer, wait-for-selector, JS enabled. SSRF guard: block RFC1918/link-local/metadata IPs, cap redirects, 30 s timeout. |
| **Merge** | S | Multi-document picker with drag-reorder and per-file page ranges → PDFium page import into a new document. Options: continue page numbering, keep/flatten bookmarks, keep/discard forms. |
| **Split PDF** | S | Modes: every N pages, at bookmarks (level selector), by page ranges, by file size, extract selected. PDFium page import per output. Outputs packaged as a ZIP (`:zip`). |
| **Compress** | S | Presets: Low/Medium/High/Custom. Pipeline: enumerate embedded images via PDFium → downscale/recompress via vix (JPEG quality per preset) → rebuild via **`Quire.Pdf`** with `SaveOptions::use_object_streams(true)` + `use_xref_streams(true)`. ⚠️ **Linearization is deliberately not produced — this is a scope reduction, not an omission; see the note below.** ⚠️ Never strip `/StructTreeRoot` or `/MarkInfo` — that silently destroys tagged-PDF accessibility; if aggressive reduction genuinely needs it, make it an explicit opt-in labelled "remove accessibility tags". Show a before/after size comparison and a page-preview diff before the user commits. |
| **PDF to Word / Excel / PowerPoint** | S | `Office.Writer.{Docx,Xlsx,Pptx}` (pure Elixir): extract spans with layout from PDFium, group into paragraphs/tables/shapes, emit valid OOXML. Fidelity is best-effort — **surface this expectation in the UI** ("best for text-based PDFs"). Offer "run OCR first" when the source has no text layer (detect via `Render.extract_text`). |
| **PDF to Image** | S | PDFium render → vix encode → PNG/JPEG/TIFF/WebP at 72–600 DPI, all pages or a range, one file per page or a multipage TIFF, ZIP output. |
| **Advanced ▾ → PDF to PDF/A** | S | `Quire.PdfA` (§3.3): best-effort PDF/A-2b — verify/embed fonts, inject an ICC OutputIntent, write XMP metadata and MarkInfo, remove forbidden features (encryption, JS, external references) — then run the built-in structural conformance report and **show the report to the user, including every check that could not be verified**. Labelled "best-effort conversion" everywhere; the product never claims ISO certification (§1.2). |
| **Advanced ▾ → PDF to TXT** | S | PDFium `extract_text`, with layout-preserving and reading-order modes. |
| **Advanced ▾ → PDF to RTF** | S | `Office.Writer.Rtf`: spans → paragraphs with basic character formatting. Label it "basic formatting only". |
| **Advanced ▾ → PDF to HTML** | S | Generate HTML yourself: render each page to WebP + overlay absolutely-positioned text spans from `extract_text`, in a single self-contained file. Offer a "text only" mode using semantic reflow. |

⚠️ **Compress no longer promises linearization. This is a deliberate change
to a stated product requirement, made here rather than discovered in Phase 8.**

Earlier drafts of this row promised "rebuild via PDFium with object streams +
linearization". **PDFium cannot produce linearized output** — it can only
*detect* it; the capability is absent from the public C headers that
pdfium-render 0.8.37 vendors at `include/pdfium_7543/`, so no fork or PR
reaches it (§3.3). `lopdf` cannot linearize either, so moving the work to
`Quire.Pdf` does not recover it. There is no in-BEAM path to fast web view,
and §3.4 forbids the only tools that would provide one (Ghostscript, qpdf).

**What replaces it:** object streams + xref streams, which `lopdf` supports
directly via `SaveOptions` and which its own documentation measures at
**11–61% size reduction** — most of the win, and the win users actually asked
for, since Compress is a *file size* feature. What is genuinely lost is byte-
range progressive loading over HTTP, which matters little for a
localhost-first application whose own viewer reads from OPFS and a local
range-request controller (§14.2). Revisit only if a hosted deployment lands.

**Do not silently drop the vocabulary.** Linearization stays visible in two
places, both correct: the **Properties dialog** (§10.2) *reads and reports*
whether a document is linearized, which PDFium does support; and
`linearized.pdf` stays in the fixture corpus (§13) as a read-path fixture.
T-083's acceptance criterion is a size reduction, never a `/Linearized`
dictionary in the output.

**Batch** (the Home tile) is this tab's operations applied to N files with a
saved recipe — see §10.1.

**Acceptance:** every conversion produces an `operations` row with live
progress; failures show a plain-language cause; a 50 MB, 500-page document
converts without OOM (stream, never load a whole PDF into a binary).

### 9.3 Page

*Reference: screenshot 8.*

The Page tab replaces the document canvas with a **thumbnail workspace**: a
responsive grid of page cards with multi-select (click, shift-click,
ctrl-click), drag-to-reorder, an insertion caret between pages, a zoom slider
sizing the thumbnails, and a grid/single-page toggle.

All structural operations are implemented with the PDFium NIF's page-import
and page APIs: build a new document, import pages in the desired order/ranges
from the source(s), apply box/rotation changes, save as a new revision.

| Control | Side | Implementation |
|---|---|---|
| **Insert** | C→S | Insert blank page(s), from file, from clipboard, from scanner — at a chosen position. |
| **Extract** | S | Extract selected pages to a new document; option "delete after extracting". |
| **Replace** | S | Replace selected pages with pages from another file (source range picker). |
| **Move** | C→S | Enabled only with a selection. Drag-reorder is optimistic on the client (`page.move` op), committed via page import in the new order. |
| **Reverse** | S | Reverse selection or whole document. |
| **Background** | S | Colour, image, or another PDF as a background; scale/position/opacity/rotation; page range. PDFium page objects drawn beneath existing content. |
| **Size** | S | Resize pages to A4/Letter/Legal/A3/custom; scale-to-fit vs stretch; anchor. MediaBox change + content transform. |
| **Margin** | S | Add/remove margins in mm/in/pt per side; box manipulation. |
| **Export images** | S | Extract all embedded raster images at native resolution (PDFium image extraction), with a minimum-dimension filter, as a ZIP. |
| **Page crop** | C→S | Interactive crop rectangle on the thumbnail or full page; apply to current page / selection / all / odd / even; set CropBox (reversible) not MediaBox. Live preview. |
| **Remove crop** | S | Reset CropBox to MediaBox. Because crop only touched CropBox, this is lossless. |
| Rotate (context menu) | C→S | 90° CW / CCW / 180° on selection — **persistent**, unlike View → Rotate view. |
| Delete (context menu / `Del`) | C→S | With undo. |

**Acceptance:** reordering 200 pages by drag stays responsive (virtualise the
grid); all page ops are undoable; crop is reversible.

### 9.4 Fill & Sign

*Reference: screenshot 4.*

A lightweight self-signing tab, distinct from Forms (§9.8, authoring) and
E-Sign (§9.9, multi-party workflow).

| Control | Side | Implementation |
|---|---|---|
| **Signature** ▾ | C→S | Create from: **Draw** (pointer-events canvas with pressure-aware smoothing), **Type** (5 script fonts), **Upload image** (auto background removal — threshold to alpha). Saved signatures live in `user_settings`. Placement: click on the page → resizable, movable box. Renders via pdf.js `SignatureEditor`, committed as a flattened XObject. |
| **Initials** ▾ | C→S | Same, separate saved slot. |
| **Signer's name** | C | Insert a text stamp of the account name at click point. |
| **Signing date** | C | Insert a formatted date stamp; format configurable in settings. |
| **Text** (palette) | C | Free-text box with font/size/colour, auto-sizing to content. |
| **Crossmark** ✕ | C | Vector glyph, resizable, snaps to nearby form-field-sized boxes. |
| **Checkmark** ✓ | C | Same. |
| **Filled Dot** ● | C | Same — for radio-button-style paper forms. |
| **Line** | C | Straight line, adjustable weight and colour; shift-constrain to horizontal/vertical. |

The palette floats below the ribbon (per the screenshot), stays visible while
the tab is active, and shows the active tool highlighted. `Esc` deactivates.

**Auto-detect fields:** on entering the tab, run field detection (PDFium
`form_fields`, plus a heuristic line/box detector over the rendered page for
scanned forms) and offer "Fill automatically" — placing text boxes over
detected fields. This is the single highest-value quality-of-life feature in
the tab.

**Acceptance:** a placed signature survives save/reload at the correct
position and scale on rotated and non-origin-cropped pages. (Coordinate
handling is the usual bug source — see §14.3.)

### 9.5 Edit

*Reference: screenshots 5, 6, 7.*

The most complex tab. **Set expectations honestly in the UI:** editing text
in a PDF is inherently approximate. Implement two modes:

- **Add mode** (reliable) — new text objects laid over the page.
- **Edit mode** (best-effort) — modify existing text runs. Use PDFium's text
  extraction with per-character bboxes and font metrics to identify a run,
  then rewrite that run's content stream via `Quire.Compose`. Refuse
  gracefully (with a clear message) when the font is not embedded or is
  subset without the needed glyphs, offering "convert to editable text via
  OCR" instead.

| Control | Side | Implementation |
|---|---|---|
| **Add text** | C→S | Click or drag to create a text box; opens the floating format bar. Uses pdf.js `FreeTextEditor` for interaction, `@cantoo/pdf-lib` for the committed object. |
| **Insert image** | C→S | Upload/drag PNG/JPEG (convert others server-side via vix first — `@cantoo/pdf-lib` embeds PNG and JPEG only). Resize with aspect lock, rotate, set opacity, reorder z-index, crop. |
| **Link** | C→S | Drag a rectangle → opens the **Add Action** modal (below). Also converts selected text into a link. |
| **Format painter** | C | Copy the style of a selected text/annotation object, apply to the next click. Disabled until something is selected. |
| **Select text** | C | Switches the pointer to text-selection mode over the existing content (as opposed to object selection). |
| **Page number** | S | Position (6 anchors), format (`1`, `i`, `I`, `a`, `A`, `Page 1 of N`), start-at, page range, font/size/colour, margin. `Compose` generates the stamp text; PDFium page objects apply it. |
| **Watermark** | S | Text or image; opacity, rotation, scale, tiling, position, front/behind content, page range. Same stamping mechanism. |
| **Header and footer** | S | Left/centre/right slots × header/footer, with tokens `{page}`, `{pages}`, `{date}`, `{time}`, `{filename}`, `{author}`. Same stamping mechanism. |
| **Bates numbers** | S | Prefix/suffix, digit count, start number, position, font. Must continue across a merged set — store the last number used on `documents.origin_metadata`. |
| **Remove page marks** ▾ | S | Remove page numbers / watermarks / headers & footers / Bates / **all**. Only removes marks *this app applied* (tracked in `text_edits`); for foreign marks, offer "Search and redact" instead and say so. |
| **Spell check** ▾ | C | Language selector + check-as-you-type in text boxes via the browser's native spellcheck in `contenteditable`. The document-wide "check document" report runs a pure-Elixir dictionary pass (compiled wordlist per language, shipped as app data) over `extract_text` output. |
| **Ruler** | C | Horizontal + vertical rulers in the current unit (pt/mm/in), with a draggable guide system. Toggle persists to `user_settings`. |
| **Grid** | C | Configurable grid with snap-to-grid for object placement. Toggle persists. |

**Floating text format bar** (screenshot 6) appears when a text object is
selected: font family combo (embedded + standard-14 + uploaded), size combo,
**B**, *I*, font colour, highlight colour, strikethrough, underline,
alignment (with a dropdown for justify), decrease/increase indent,
anchor/link button, overflow menu (line spacing, character spacing,
superscript/subscript, case), properties (sliders icon), close. It positions
above the selection, flipping below when there is no room, and never overlaps
the ribbon.

**Add Action modal** (screenshot 7): a card grid of action types with an
overflow `⋮` for the rest, then a type-specific form, then `Apply` (disabled
until valid) / `Cancel`.

- **Open web page** — URL field with scheme validation, "open in new window".
- **Open file** — a `Ref` picker (attachment or embedded file).
- **Go to page** — page number + zoom/fit setting (a named destination).
- Overflow: **Go to named destination**, **Execute menu item**, **Submit
  form**, **Reset form**, **Show/hide field**, **Run JavaScript** (⚠️
  default **off**; if enabled, never execute it server-side and sandbox it
  in the viewer via pdf.js's `PDFScriptingManager` + `pdf.sandbox.mjs`).

**Acceptance:** added text renders identically in Acrobat/Chrome/Preview;
undo/redo works through a 50-operation edit sequence; the format bar never
covers the object being edited.

### 9.6 Comment

*Reference: screenshot 9.*

All annotation types are standard PDF annotations, authored client-side via
pdf.js's editor layer where available and via `@cantoo/pdf-lib` otherwise,
mirrored into the `annotations` table and the journal.

| Control | Side | Notes |
|---|---|---|
| **Text** | C | Free-text callout (`/FreeText`). |
| **Highlight** / **Strikethrough** / **Underline** | C | Text-markup annotations from the selection's quad points. A **Squiggly** option belongs in the same group. |
| **Sticky note** | C | `/Text` annotation with an icon set (note, comment, key, help, paragraph), colour, and a threaded reply popup. |
| — | — | ⚠️ **Entry point:** `AnnotationEditorLayer` is exported from `build/pdf.mjs`, **not** from `web/pdf_viewer.mjs`, and cannot be driven standalone (it needs an `AnnotationEditorUIManager`). When using `PDFViewer`, drive it through `PDFViewer.annotationEditorMode` + `annotationEditorParams` and the EventBus events. Do not instantiate the layer yourself. |
| **Pencil** | C | `/Ink` — pointer-events with coalesced-event capture for smooth strokes, configurable width/colour/opacity, plus an eraser. |
| **Attachment** | C→S | `/FileAttachment` — embed any file, shown as a pin icon; the Attachments panel lists and extracts them. |
| **Stamp** | C | Built-ins (Approved, Draft, Confidential, Reviewed, For Public Release, Sign Here…), plus custom image/text stamps saved per user. |
| **Line** ▾ | C | Line, Arrow, Double-arrow, Dimension line with measurement label. |
| **Oval** ▾ | C | Oval, Rectangle, Polygon, Cloud, Polyline. Fill/stroke/opacity. |
| **Advanced** ▾ | C | Text callout with leader, Measure (distance/perimeter/area with a scale calibration dialog), Sound/Video (`/RichMedia` — link only, do not embed player code). |
| **Whiteout** | C | An opaque filled rectangle matching the page background. **Must warn that this is cosmetic — the text underneath remains extractable.** Offer "Redact instead" in the same toast. This distinction is a genuine data-leak risk and the UI must be unambiguous. |
| **Compare** | S | Two-document or two-revision comparison: text diff (align extracted spans, LCS diff, highlight insert/delete/change) plus a visual pixel diff of rendered pages (both sides rendered by the PDFium NIF; diff computed in Elixir). Presents in the Side-by-side view with synchronised scroll and a change list panel. |
| **Export comments** | S | Formats: FDF, XFDF, CSV, and a printable summary PDF — all generated in Elixir (FDF/XFDF are small text formats; the summary PDF via PDFium page objects). Import the same. |

A **Comments panel** in the left rail lists all annotations grouped by page,
filterable by author/type/date/status, with reply threads and
resolved/unresolved status.

**Acceptance:** annotations round-trip through Acrobat without loss; ink
strokes are smooth at 120 Hz pointer rates; whiteout shows the warning every
time until the user dismisses it permanently.

### 9.7 Secure

*Reference: screenshot 10.*

| Control | Side | Implementation |
|---|---|---|
| **Restrict Permissions** | S | Owner password + permission flags: print, print high-quality, modify, copy/extract, annotate, fill forms, extract for accessibility, assemble. `Quire.SecurityHandler` implements the standard security handler (AESV2 128-bit, AESV3 256-bit) per ISO 32000-2 §7.6 over `:crypto` with `Quire.Pdf` for `/Encrypt` dictionary writes — key derivation, per-object stream/string encryption. Also sets a user (open) password. Passwords MUST be posted over the LiveView channel and never logged; zero the assign immediately after use. |
| **Digital signature** | S | `Quire.Pades` (over OTP `:public_key`/`:crypto` + `Quire.Pdf` for byte-range and DSS structure writes): parse PKCS#12 keystores, build the CMS (PKCS#7) detached signature over the byte range, embed it with a visible appearance, support PAdES **B-B** (basic) and **B-T** (+ RFC 3161 timestamp via Req against a configured TSA), and append DSS/VRI for **B-LT** so signatures validate long-term. RSA and ECDSA keys. Flow: choose or upload a certificate → place the visible field → sign → validate → store a `digital_signatures` row. **Validation is also native:** parse the CMS, verify the chain, check the timestamp token, and run difference analysis (bytes appended after signing) for the Signatures panel. ⚠️ This is cryptographic code written in-house — the acceptance bar is interoperability: Gate 8 requires signatures produced here to validate in Acrobat, and third-party signed fixtures to validate here. See R-04. |
| **Create redaction** | C | Mark regions: drag a rectangle, or select text. Stored as `redactions` rows with a reason code and optional overlay text. Marks are visually distinct (red outline) and **not yet destructive**. |
| **Apply redaction** | S | Enabled only when unapplied marks exist. Destructive: remove the content, not just cover it. Two paths, in order of preference: (a) enumerate page content via PDFium and delete the text/image/vector objects intersecting the mark, then draw the overlay — preserves the rest of the page losslessly; (b) rasterise the affected page at 300 DPI with the region blanked and replace the page (lossy but bulletproof — automatic fallback for pages where (a) cannot prove completeness, e.g. the mark overlaps a Type-3 glyph or an unparseable content stream). After applying, **verify** by re-extracting text and asserting the redacted strings are absent; fail the job if they are not. |
| **Search and redact** | C→S | Regex/literal search across the document, plus presets (SSN, credit card, email, phone, IBAN), preview of all hits with per-hit accept/reject, then Apply. |
| **Remove metadata** | S | Strip `/Info` and XMP: author, title, subject, keywords, creator, producer, dates. Show a before/after table. |
| **Sanitize** | S | Remove JavaScript, embedded files, launch actions, external references, form data, hidden layers, deleted-but-present objects, and metadata. Enumerate via PDFium inspection + a full object walk in Elixir, present as a checklist of what was found and what will be removed, then rewrite via PDFium save. |

**Acceptance:** an applied redaction survives text extraction, copy/paste,
and image analysis of the output; encryption round-trips through Acrobat; a
signature applied here validates in Acrobat; the UI never conflates whiteout
with redaction.

### 9.8 Forms

*Reference: screenshot 11.*

Authoring AcroForm fields (filling them is §9.4).

| Control | Side | Implementation |
|---|---|---|
| **Text field** | C→S | Drag to place; properties: name, tooltip, default, required, read-only, max length, multiline, password, comb, alignment, format (number/date/currency/percentage/custom), validation, calculation. |
| **Combo box** | C→S | Options list (value + label), editable flag, sort, default. |
| **List box** | C→S | Options, multi-select flag. |
| **Signature** | C→S | Signature field placeholder; can be assigned to an e-sign signer (§9.9). |
| **Check box** | C→S | Export value, default state, style (check/cross/diamond/circle/star/square). |
| **Radio button** | C→S | Group name + export values; placing multiple in a group. |
| **Button** ▾ | C→S | Push button with an action (reuses the Add Action modal), plus **Submit form** and **Reset form** presets. |
| **Highlight fields** | C | Toggle the light-blue field overlay. Persist to settings. |
| **Form data** ▾ | S | Import/Export FDF, XFDF, JSON, CSV (all generated/parsed in Elixir); "Flatten form" (bake values into content via PDFium flatten). |
| **Reset** | C | Clear all values; disabled when the form is empty. |

Provide a **field list panel** with tab-order editing (drag to reorder), and
an **auto-create fields** action that detects form-like structures in a
scanned document.

**Acceptance:** a form authored here opens and fills correctly in Acrobat and
in Chrome's built-in viewer; tab order matches the authored order; calculated
fields recompute.

### 9.9 E-Sign

*Reference: screenshot 12.*

A multi-party signature request workflow. This is a small product in its own
right — scope it carefully.

| Control | Side | Implementation |
|---|---|---|
| **Sign your document** | C→S | Self-sign shortcut → §9.4 flow, then optionally a PAdES digital signature (§9.7) for cryptographic assurance. |
| **Request signature** | S | Wizard: (1) add signers (name, email, order, role), (2) place fields per signer (signature, initials, name, date, text, checkbox) colour-coded by signer, (3) compose subject/message, (4) set expiry and reminder cadence, (5) send. Creates `esign_envelopes` + `esign_signers` + `esign_fields`. |
| **Inbox** ▾ | S | Two views: **Sent** (envelope status, per-signer progress, resend, void, download certificate) and **Received** (documents awaiting your signature). |
| **My signature** | C | Manage saved signature/initials appearances (shared with §9.4). |
| **Manage signers** | S | Address book of frequent signers; reusable groups. |

**Signer-facing route** — a public LiveView at `/sign/:token`, outside the
authenticated app: identity confirmation, document review with required-field
enforcement, consent to electronic signing (ESIGN/UETA disclosure text),
signing, and a completion receipt. Tokens are single-purpose, expiring, and
rate-limited.

**Audit trail** (`esign_audit_events`) MUST record: envelope created, sent,
viewed (with IP + user agent + timestamp), each field completed, signed,
declined, completed, downloaded. Generate a **certificate of completion**
PDF (built with PDFium page objects) appended to the final document, and
apply a document-level PAdES B-LT signature at completion (via
`Quire.Pades`) so tampering is detectable.

**Compliance note for the product owner (not a legal opinion):** ESIGN/UETA
(US) and eIDAS simple/advanced electronic signatures (EU) are what this
design supports. **Qualified** electronic signatures under eIDAS require a
qualified trust service provider and are out of scope.

**Acceptance:** an envelope with 3 sequential signers completes end-to-end;
the audit certificate matches the events; a tampered completed document fails
signature validation.

### 9.10 OCR

*Reference: screenshot 13.*

OCR is a pure in-BEAM pipeline (`Quire.Ocr.Engine`, §3.3): rasterise each
page with the PDFium NIF at 300 DPI → preprocess with vix (deskew, denoise,
optional clean) → recognise with the Tesseract NIF → compose the output PDF
by placing the recognised text as an invisible text layer over the untouched
original page (sandwich mode), saved as a new revision. No intermediate
files, no external orchestrator.

| Control | Side | Implementation |
|---|---|---|
| **Document** | S | OCR the open document. Modes: skip pages that already have text (default), redo OCR (replace an existing OCR layer), force OCR (ignore existing text). Produces a new revision with the invisible text layer. |
| **Scan and recognize** | C→S | Acquire from camera (§9.2), then OCR in one flow. |
| **External image** | S | OCR standalone images into a searchable PDF. |
| **OCR options** | C | Languages (multi-select; download tessdata packs on demand and cache), output mode (skip / redo / force), deskew, rotate pages automatically, clean/denoise, image optimise level 0–3 (vix recompression), and a per-page confidence report. |

Store per-page confidence (reported by the Tesseract NIF per word, aggregated
per page) in `ocr_results.page_confidences` and surface a "low confidence
pages" list so the user can re-run those pages with different settings.

**Acceptance:** a 50-page scanned document OCRs at **≥ 1 page/s** on the
target machine (§14.1 — Apple Silicon, plugged in, `ocr: 1`); the result is
searchable in Chrome's viewer; the original page images are visually
unchanged.

### 9.11 Translate

*No reference screenshot — designed from first principles.*

| Control | Side | Implementation |
|---|---|---|
| **Translate document** | S | Extract text with layout (PDFium spans) → translate → re-render with `Quire.Compose`. |
| **Source / target language** | C | Auto-detect source; ~60 target languages. |
| **Mode** | C | **Overlay** (translated text over the original, original preserved underneath), **Sidecar** (side-by-side bilingual output), **Replace** (translated text replaces the original in place — best effort, reflow issues expected). |
| **Selection translate** | C→S | Translate the current text selection into a popup. |
| **Glossary** | C | Per-document term overrides that the translator must honour. |
| **Translate comments** | S | Translate annotation contents rather than page text. |

Provider behind a `Quire.Translation.Provider` behaviour so the LLM/MT
vendor is swappable. Text length is billable — show an estimated cost/token
count before running, and cache by `sha256(text) + langs` in
`translation_cache` (§5.5).

**Locally:** the API key lives in `.mise.local.toml` (gitignored), never in
`config/*.exs` and never in the repo. Ship a `Provider.Null` implementation
that returns the source text unchanged with a visible "translation disabled"
banner, and make it the **default** — so a fresh clone runs, the tab renders,
the tests pass, and nobody is billed for a test suite.

Translation is the only v1 feature that sends **document content** to a
third party. (Several others make outbound calls — URL-to-PDF fetches a page,
signing hits a TSA, e-sign sends mail, cloud connectors talk OAuth — but none
of them hand a third party the text of the user's document.) Treat that
distinction as worth a settings toggle and an explicit consent, exactly as
§11.3 describes.

**Reflow is the hard part.** Translated text is routinely 20–40 % longer
than the source. Implement: shrink-to-fit within the original bbox down to a
minimum size, then overflow into a footnote block, and mark such regions in a
review list.

---

## 10. Home, backstage and document lifecycle

### 10.1 Home screen (`HomeLive` at `/`)

*Reference: screenshot 00.*

**Left tile grid**, 2 columns, 140×140 px cards, 24 px icon over a two-line
label, hover elevation:

| Tile | Behaviour |
|---|---|
| Open PDF | File picker → upload → `/workspace/:id` |
| Clipboard to PDF | §9.2 |
| Merge files to PDF | Multi-select → merge wizard |
| Convert to PDF | §9.2 File to PDF |
| PDF to Word | Upload → convert → download |
| PDF to Excel | Same |
| Add comment | Upload → open on the Comment tab |
| Protect your PDF | Upload → open the Restrict Permissions dialog |
| **Batch** | Recipe builder: pick files, chain operations (convert → OCR → compress → watermark → protect), run as one `batch_jobs` row with per-file progress and a ZIP result. Recipes are saveable and re-runnable. |
| **Customize** | Reorder/show/hide tiles; persists to `user_settings`. |

**Right panel** — `Recent` heading, `Clear all`, `Sort by` (Last opened /
Name / Size / Type / Date created), grid/list toggle. Cards show a thumbnail
(rendered by the `:render` queue on first open and cached as
`document_pages.thumbnail_ref`), filename, and a context menu (Open, Open
containing folder [desktop only], Pin, Remove from list, Delete).

Empty state: a drop zone reading "Drop a PDF here or choose a tool to
start". The whole Home surface accepts drag-and-drop onto it.

Two floating buttons bottom-right: feedback and support.

### 10.2 Backstage (File menu)

*Reference: screenshot 0.*

A full-window overlay inside `WorkspaceLive`, with an accent-coloured back
arrow top-left.

**Left rail:** New, Open, Save, Save as, Save optimized, Properties, Print,
Print selection, Exit. `Save` is disabled when the document is not dirty.

| Item | Behaviour |
|---|---|
| **New** | Blank (size/orientation), From template, From file, From clipboard, From scanner. |
| **Open** | Source column: **Recent** (clock icon), **Computer** (monitor icon), **Add account** (+). |
| **Save** | Materialise the journal into a new revision (§7.4). Web: also writes to the user's library. Desktop: writes back to the original path. |
| **Save as** | New `documents` row; web offers download + library copy. |
| **Save optimized** | Save, then a compress job; shows the size delta. |
| **Properties** | Modal: Description (title, author, subject, keywords), Security summary, Fonts (embedded/subset list), Custom metadata, Initial view (layout, magnification, open-to page, hide toolbars), Statistics (size, pages, PDF version, producer, dates, tagged, linearized). Editable fields commit as a `doc` op. |
| **Print** | Browser print of a print-optimised render, with page range, copies, scale (fit/actual/custom), duplex hint, "annotations/comments/form fields" toggles, booklet and N-up layout. Generate a flattened print PDF server-side (PDFium rasterise at print DPI + recompose), then `window.print()` on an iframe of it — never print the live canvas. |
| **Print selection** | Same, restricted to the selected pages or region. |
| **Exit** | Web: close the workspace tab, prompting on unsaved changes. Desktop: quit the app. |

**Open → Computer pane** — `Open from Computer` heading, `Browse…` button, a
`↑ This PC` breadcrumb, **Local Folders** (Desktop, Documents, Downloads,
App Files, Current Document Location) and **Devices and drives**.

- **Web build:** `Browse…` opens the file dialog via a hidden file input
  wired to LiveView uploads. The Local Folders and Devices lists are
  **replaced by a cloud/library browser** — "My documents", "Shared with
  me", and any connected cloud accounts — rendered with the same visual
  treatment so the layout is unchanged. Do not attempt to emulate drives.
- **Desktop build:** the same component calls `Storage.pick_open/1`, and the
  folder list is populated from real OS locations, including drives. This is
  the payoff for the §7.1 abstraction: **one component, two adapters, no
  branching in the LiveView.**

**Add account** — OAuth flows for Google Drive, Dropbox, OneDrive, Box, plus
S3 and WebDAV with manual credentials. Stored in `cloud_connections` with
encrypted tokens. Browsing a connected account lists remote files and
streams the chosen one into `Storage`.

### 10.3 Document open pipeline

Every path into the workspace converges here:

1. Bytes land in `Storage` → `Ref`.
2. `Documents.ingest/2`: validate the PDF header, detect encryption (PDFium
   load attempt reports a password requirement), and if encrypted prompt for
   the password before anything else touches it.
3. `Render.page_count` + `page_geometry` → `document_pages` rows.
4. Create `documents` + revision 1.
5. Enqueue thumbnail rendering (`:render`) and a text-layer probe (does the
   document have extractable text? drives the "run OCR first" prompts).
6. Insert/update `recent_documents`.
7. Navigate to `/workspace/:id`; the viewer hook streams the bytes via a
   **range-request-capable controller** (`document_controller.ex`) so pdf.js
   can fetch progressively — do not send the whole file in one response.

**Corrupt-file handling:** PDFium's loader is deliberately tolerant and
repairs broken xref tables on load. Attempt a load-and-resave repair, tell
the user what was wrong, and open the repaired copy as revision 1 with a
note. Files that even tolerant loading rejects get a clear, specific error —
never a crash.

---

## 11. Accounts, licensing, settings

### 11.1 Accounts

`mix phx.gen.auth` runs in **Phase 0 (T-200)**, not in this phase — it owns the
`users` + `users_tokens` migration (§5.1) and everything downstream assumes a
session already exists. Phoenix 1.8.9 generates magic-link **and** password
log-in, email confirmation, and sudo mode for sensitive actions (changing
security settings, managing certificates) out of the box. T-162 is polish on
top of that; optional TOTP 2FA is T-163. Sessions are LiveView-aware through
the generated `Quire.Accounts.Scope` struct, assigned as `@current_scope`
(`on_mount {QuireWeb.UserAuth, :require_authenticated}`; siblings are
`:mount_current_scope` and `:require_sudo_mode`).

**Open product decision — classic password reset.** Phoenix 1.8.9 ships *no*
forgot-password flow; recovery is the magic link, and password changes live in
the generated settings LiveView. This section previously promised "password
reset". That promise is not deleted here, because dropping a stated
requirement silently is worse than carrying it: if a conventional
forgot-password email is actually wanted, it is **new work with its own task**,
not generator output. Decide before Phase 12.

The account avatar in the title bar shows a notification dot for: pending
e-sign requests, completed background jobs, and licence expiry warnings.

### 11.2 Licensing

The reference has a persistent `Activate now` button, so tiering is part of
parity.

| Tier | Includes |
|---|---|
| **Trial** (14 days) | Everything, watermarked output on export |
| **Standard** | View, annotate, fill & sign, basic convert, merge/split, compress |
| **Premium** | + Edit, Forms, Secure, OCR, batch |
| **Business** | + E-Sign, Translate, cloud connectors, team seats |

Implement `Quire.Licensing.allows?(user, :feature_key)` and a
`<.gated feature={:ocr}>` component that renders an upsell overlay instead of
the control. Gate in **three** places or it leaks: the component, the
LiveView event handler, and the Oban worker. Never rely on hiding UI alone.

`Activate now` opens a modal for entering an activation key or starting a
checkout; keys validate against `licenses`.

### 11.3 Settings

General (theme, language, units, default zoom/view mode, autosave), Editing
(default fonts/colours, snap, ruler/grid defaults), OCR (default languages,
tessdata management), Security (default encryption strength, certificate
store), Privacy & translation (provider, consent, data retention — see
§9.11), Connected accounts, Keyboard shortcuts (viewer + editor), About (app
version, **the engine version table from §7.2** — PDFium, Tesseract, libvips,
Chromium, OTP, Elixir, Postgres — and the load state of every engine; on a
Homebrew machine that table is the first thing you will want when something
behaves differently than it did yesterday).

---

## 12. Desktop packaging (Phase 13)

**Do not write any desktop-specific code before Phase 13.** If §7.1 and §7.2
were followed, this phase is additive.

Because v1 already runs natively on macOS and the engine layer is in-BEAM,
this phase is small: Rust comes from mise, the native libraries are already
`arm64` dylibs bundled inside the NIF artefacts (or one Homebrew formula),
and there is no collection of external tools to redistribute — no JVM, no
Python, no office suite. What remains is genuinely desktop work: the shell,
native file dialogs, localhost auth, code signing and notarisation, plus the
two platforms you have not been developing on.

**Two things make it less small than that paragraph reads, and both are
licence/redistribution problems rather than code problems.** The bundled
libvips dylib carries an LGPLv3 relink duty that constrains how the `.app` may
be signed (step 9 below — the *only* place that decision is recorded), and
`image_ocr` links live into `/opt/homebrew`, so OCR is not redistributable
until T-180 lands. Budget them as their own work, not as notarisation
paperwork.

### 12.1 Chosen path: Tauri v2 shell + Elixir release as a child process + ElixirKit

**Tauri** `tauri` crate **2.11.x**. **ElixirKit** `elixirkit` **0.1.0**
(Apache-2.0, maintained by Dashbit) provides the Rust↔Elixir channel. Note
there is **no `elixirkit` crate on crates.io** — the Rust side is a path
dependency into the Hex package. This is the architecture Livebook ships in
production, which is the strongest available evidence that it works.

1. `tauri.conf.json` `beforeBuildCommand` builds a prod release
   (`MIX_ENV=prod mix release`) into `src-tauri/target/rel`, bundled via
   `bundle.resources`.
2. Rust: ElixirKit PubSub listen on a loopback TCP port, spawn the release
   with `ELIXIRKIT_PUBSUB` in its env.
3. The Elixir supervision tree adds the ElixirKit PubSub child with an
   `on_exit` that stops the VM, and broadcasts `ready:<url>` once the
   endpoint is listening. Rust opens the window at that URL.
4. Endpoint: bind `{127,0,0,1}` on a free port injected by Rust as `PORT`,
   with `SECRET_KEY_BASE`, `PHX_SERVER=true`, `PHX_HOST=localhost`, so both
   sides know the address without discovery.
5. **Use `localhost` consistently on both sides.** Phoenix's
   `check_origin: true` compares the `Origin` **host** against
   `url: [host: ...]` — and `127.0.0.1` does not equal `localhost`, so
   navigating the webview to `http://127.0.0.1:PORT` while the endpoint is
   configured for `localhost` produces a 403 on the LiveView socket. Bind to
   `{127,0,0,1}` (an interface, not an origin) but navigate to
   `http://localhost:PORT` and set `url: [host: "localhost"]`.
6. Set `remote: {"urls": ["http://localhost:*"]}` in the Tauri capability,
   or none of the `dialog`/`fs` permissions apply to your localhost-served
   page. This is the single most common Tauri-v2 mistake with this
   architecture.
7. `Storage.Local` becomes the adapter; `pick_open`/`pick_save` call the
   `dialog` plugin via a colocated hook and return real paths.
8. Native libraries: the PDFium dylib travels inside the `ex_pdfium`
   artefact and libvips inside the vix artefact. Tesseract + tessdata must
   become **redistributable artefacts you ship**, not a Homebrew formula you
   assume — either statically linked into the NIF build (preferred; decide in
   T-019's ADR) or bundled dylibs with `install_name_tool` fix-ups. Verify
   with `otool -L` that no bundled binary links back into `/opt/homebrew`.
   **`File.chmod!(path, 0o755)` on first use** for anything executable — do
   not assume the executable bit survives archive round-trips. This is the
   step ADR 0002 names as the trigger for T-180: `image_ocr` links live into
   `/opt/homebrew`, so a NIF built that way **cannot ship in a distributed
   `.app`**, and `image_ocr` does not build on Windows at all — which blocks
   T-183 independently of T-180.

9. **The LGPLv3 §4 decision — this step is its only home.** §3.5 establishes
   *that* the obligation exists (the bundled `libvips-cpp.8.18.3.dylib` is a
   statically Combined Work conveyed under LGPL-3.0-or-later); this step is
   where it is *discharged*. Do not re-decide it anywhere else.

   **Decision: discharge LGPLv3 §4(d)(0) — convey the Minimal Corresponding
   Source and enable relinking — rather than rebuild libvips against a v2.1
   dependency set.** Rationale: the alternative means owning a from-source
   libvips build across every target triple, which is strictly larger than
   T-180's already-large Tesseract problem and buys only a licence-version
   change. Note the two §4(d) options are alternatives and only (d)(0) is
   available here: (d)(1)'s "suitable shared library mechanism" requires a
   mechanism that "uses at run time a copy of the Library **already present on
   the user's computer system**", which a dylib we ship inside our own bundle
   is not. So (d)(1) is unavailable, and the replaceable-dylib packaging below
   is not (d)(1) compliance — it is what makes the (d)(0) relink right real
   rather than theoretical. It is a good fit because `vix.so` **already** links
   libvips dynamically via
   `@rpath/libvips-cpp.8.18.3.dylib` under
   `LC_RPATH @loader_path/precompiled_libvips/lib` — the mechanism exists; it
   is the *packaging* that currently defeats it by sealing the dylib inside a
   signed bundle. Concretely, the `.app` MUST:

   - keep `libvips-cpp.8.18.3.dylib` as a **replaceable file** in
     `Contents/Frameworks/` (or `Contents/Resources/`), never `install_name_tool`-ed
     into the NIF and never merged into a single binary;
   - be **signed with the hardened runtime's library-validation exception**
     (`com.apple.security.cs.disable-library-validation`), or a user-supplied
     replacement dylib will be refused at load and the §4(d)(0) relink
     right is not actually exercisable. **This is the load-bearing detail** — sign it the ordinary way
     and the relink right is theoretical;
   - ship the **complete corresponding licence texts** for every component
     enumerated in §3.5, plus a written offer and a build recipe naming
     `akash-akya/sharp-libvips` `v8.18.3-rc1`, since the artefact we consume
     contains no licence files at all;
   - state the LGPL-3.0-or-later notice in Settings → About alongside the
     version table (§7.2).

   T-180 owns the mechanics and T-181 owns the signing flags. If Apple ever
   makes the library-validation exception unavailable for notarised
   distribution, this decision reopens and the fallback is a v2.1 rebuild —
   record that reversal here, not in §3.5.

### 12.2 Security for the localhost server

Anything running on the machine can reach `127.0.0.1:PORT`. Mint 32 random
bytes per app run, hand them to the webview as a query token on first
navigation, compare with `Plug.Crypto.secure_compare/2`, promote to a session
flag, and 401 everything else. Use an **ETS session store** rather than
cookies inside the embedded webview.

**Keep `check_origin: true`.** Phoenix's `true` branch compares host only,
not port, so `url: [host: "localhost"]` works with a random port — provided
the webview actually navigates to `localhost` and not `127.0.0.1` (§12.1
step 5). Do not set it to `false` — Phoenix raises at boot if both
`check_origin` and `check_csrf` are false, and disabling origin checking
opens CSWSH.

Generate `secret_key_base` at runtime in `runtime.exs`, never in
`config.exs` (a compile-time secret is baked into the release and identical
for every install).

### 12.3 Rejected alternatives

- **ElixirDesktop** — unmaintained (last Hex release long ago), installers,
  code signing and auto-update all unbuilt, and it requires an OTP built
  with `:wx`, which §3.6.3 deliberately excludes. It also requires
  `use Desktop.Endpoint` *today*, coupling the web build to a desktop
  library. It is, however, the only route to iOS/Android from the same
  LiveView codebase; revisit only if mobile becomes a requirement.
- **Burrito alone** — produces a single-file *CLI* executable, not a window.
  Useful only as a sidecar, and then it forces target-triple filename
  gymnastics, first-run extraction delay, and stale-payload cache confusion.
  A plain `mix release` into `bundle.resources` is simpler; do that.
- **ex_tauri** — the nicest DX by far, but very young and pinned to an older
  OTP. **Read its source and steal the patterns; do not depend on it.**
- **Electron** — pick this only if webkit2gtk on older Linux distros breaks
  the UI. Electron guarantees one Chromium everywhere, at ~10× the bundle
  size and no Elixir integration library.

### 12.4 Platform webview caveat

Tauri uses **WebView2 (Chromium)** on Windows, **WKWebView** on macOS and
**webkit2gtk** on Linux. Test the ribbon and the pdf.js canvas on all three
before shipping; Linux is where CSS surprises appear. This is another reason
§7.1 forbids the File System Access API — it does not exist in WKWebView or
webkit2gtk. Note also that the desktop build can rely on the bundled webview
for URL→PDF on Windows (Chromium), but must keep the configured-browser path
on macOS/Linux, where the webview is not Chromium.

---

## 13. Testing strategy

| Layer | Tool | What |
|---|---|---|
| Unit | ExUnit | Contexts, `Storage` adapters (both), engine wrappers, OOXML reader/writers, PAdES + security handler against reference vectors, journal invert/replay |
| Property | StreamData | Journal: apply-then-undo returns the original state for every op kind. This catches more real bugs than any other single test. |
| Integration | ExUnit + fixture corpus | Every engine against real PDFs/Office files/images |
| LiveView | `Phoenix.LiveViewTest` | Ribbon interactions, modal flows, upload flows |
| Browser E2E | Playwright (`npx playwright install chromium`, T-199) | Open → annotate → save → reload → verify; cross-tab flows; keyboard nav |
| Visual regression | Playwright screenshots | Chrome layout per tab at 3 widths, light + dark |
| PDF correctness | Custom | Render output at 150 DPI and pixel-compare against golden images; assert text extraction after redaction; assert signatures validate |
| A11y | axe-core via Playwright | Zero critical violations per phase |
| Load | `Benchee` | 20 concurrent conversions on *this* machine; assert no queue starvation and no scheduler stall |
| NIF crash-fuzz | ExUnit + corpus | Run the entire fixture corpus through every NIF in Phase 0 and in `mise run check`; a crash here is a release blocker |

**Running it locally.** `mise run test` sets `MIX_ENV=test`, ensures
`quire_test` exists and runs `mix test`. Two machine-specific
constraints:

- **`async: true` and `convert: 1` do not mix.** Any test that drives
  Chromium must be `async: false` or serialised behind a named lock —
  concurrent browser instances produce flaky timeouts that look like bugs in
  your code. Tag them `@moduletag :serial` and run a second pass with
  `--max-cases 1`.
- **Visual-regression baselines are per-platform.** macOS renders text
  differently from Linux, so baselines captured here will not match a hosted
  CI runner. Commit baselines under `test/visual/darwin-arm64/` from the
  start, so adding a second platform later is adding a directory rather than
  invalidating everything. T-196 covers the rest.

**Fixture corpus** — build this in Phase 0 (T-016). It is the
highest-leverage 30 minutes in the project:

`simple_text.pdf`, `scanned_300dpi.pdf` (no text layer), `cjk.pdf`,
`rtl_arabic.pdf`, `acroform.pdf`, `xfa_form.pdf`, `encrypted_user_pw.pdf`,
`encrypted_owner_pw.pdf`, `signed_pades.pdf`, `tagged_accessible.pdf`,
`rotated_pages.pdf`, `cropped_nonzero_origin.pdf`, `500_pages.pdf`,
`50mb_images.pdf`, `corrupt_xref.pdf`, `linearized.pdf`, `pdf_a_2b.pdf`,
`with_attachments.pdf`, `with_layers_ocg.pdf`, `mixed_page_sizes.pdf` —
plus Office fixtures for the native converters: `report.docx`,
`budget.xlsx`, `deck.pptx`, `notes.odt`, `letter.rtf`.

Each phase's acceptance criteria MUST be exercised against the corpus.

---

## 14. Performance and correctness budgets

### 14.1 Budgets

Measured on the target machine — Apple Silicon, **plugged in**, Chrome, one
document open unless stated. On battery, macOS will throttle and App Nap will
deschedule background tabs; numbers taken there are not comparable and should
not be recorded.

| Metric | Target |
|---|---|
| Time to first page rendered (10 MB doc) | < 1.5 s |
| Scroll | 60 fps sustained, ≤ 5 canvases retained |
| Annotation stroke → visible | < 16 ms (never round-trip the server) |
| Undo/redo (client op) | < 50 ms |
| Thumbnail generation | ≤ 100 ms/page in the `:render` queue |
| LiveView payload per interaction | < 50 KB |
| BEAM memory per open document | < 50 MB **in Elixir binaries** (stream; never hold a whole PDF in a process). **This budget does not cover the PDFium path** — see below |
| **Native memory per in-flight PDFium call** | **≈ 1 full copy of the document, per worker, for the whole time it is queued.** Budget `render` + `transform` at `2 × max_document_size` and cap uploads accordingly |
| **BEAM RSS, idle, 3 documents open** | **< 500 MB** — you are sharing this machine with a browser and an editor |
| **OCR throughput** | ≥ 1 page/s at 300 DPI, single-language, `ocr: 1` |
| **Scheduler stall during OCR + render** | **0** — `:timer.tc` on an unrelated process stays under 5 ms while both queues are saturated. This is the NIF dirty-scheduler property (T-021/T-022), re-asserted under real load. |

### 14.2 Techniques

- Virtualise everything: pages, thumbnails, comment lists, page grids.
- `phx-update="stream"` for all long lists.
- Cache rendered pages in **OPFS** keyed by `sha256 + page + scale`.
- Debounce zoom re-render to 150 ms; render at the old scale transformed by
  CSS in the interim.
- Never load a full PDF into an Elixir binary — use `Storage.stream/2` and
  the range-request controller.
- Pre-render page ±2 around the viewport.

### 14.3 The coordinate system — read this before writing any placement code

Most placement bugs in PDF editors come from one of four mismatches. Put the
conversions in `assets/js/pdf/geometry.js` and a matching Elixir module, and
**never do the maths inline**:

1. **Origin.** PDF is bottom-left origin, Y up. CSS/canvas is top-left, Y
   down. `y_pdf = page_height - y_css - h`.
2. **Units.** PDF user space is points (1/72"). CSS px depend on scale and
   device pixel ratio. Always store annotations in **PDF points**, convert
   at the boundary.
3. **Rotation.** `/Rotate` of 90/180/270 rotates the *display*, not the
   coordinate space. A click at display (x,y) on a 90°-rotated page maps to
   a different user-space point. pdf.js's `PageViewport.convertToPdfPoint`
   and `convertToViewportPoint` handle this — use them, do not reimplement.
4. **CropBox ≠ MediaBox.** When CropBox has a non-zero origin, subtract it.
   Fixture `cropped_nonzero_origin.pdf` exists to catch exactly this.

Write a property test: for random page sizes, rotations and crop boxes, a
round-trip `css → pdf → css` is the identity within 0.01 pt.

---

## 15. Phased task list

Work in order. Tasks marked **∥** within a phase may be done in parallel.
Each phase ends with its acceptance gate — **do not start the next phase
until the gate passes.** Estimates assume one competent agent working
uninterrupted; they are for sequencing, not commitments.

**Total: ~22 weeks, one agent, sequential.** Ship Phases 0–4 as a usable
product before committing to the rest (R-12). Phase 4 and Phase 8 carry the
largest chunks of new in-house engine code (the native OOXML layer and the
native PAdES/security-handler work) and are sized accordingly.

---

### Phase 0 — Foundations (~1.5 weeks)

> Everything downstream depends on these abstractions. Resist the urge to
> skip ahead and "add the abstraction later" — you will not.

| ID | Task |
|---|---|
| T-001 | Choose the project name and accent colour (§2). Create the repo: `mix phx.new . --app quire --module Quire --binary-id`, generated in place so the existing repo, plan and issue database stay put (LiveView is on by default in Phoenix 1.8). Phoenix 1.8.9, Elixir 1.20.2, OTP 28. |
| T-200 | **Run `mix phx.gen.auth Accounts User users --live --binary-id --no-agents-md` immediately after `mix phx.new`, before anything else touches the schema or the markup.** It generates `Accounts`, `Accounts.User`, `Accounts.UserToken`, `Accounts.Scope` (the `current_scope` assign), `QuireWeb.UserAuth`, the auth LiveViews and session controller, the router blocks, **and the `users` + `users_tokens` migration** — so it must precede T-006 (which would otherwise duplicate `users` and break `mix ecto.migrate`), precede T-003 (it writes `{:bcrypt_elixir, "~> 3.0"}` into `mix.exs`), and precede T-025 (so its daisyUI markup is stripped in the same pass). Then: delete the generated citext extension line and retype `email` as `:string` with a `lower(email)` unique index plus `update_change(:email, &String.downcase/1)`; set `@primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}` on both schemas and `default: fragment("uuidv7()")` on both PK columns; add a confirmed dev seed user to `priv/repo/seeds.exs`. |
| T-002 | **Machine bootstrap (do this first).** Commit `mise.toml` and the `Brewfile` (Appendix B) before writing any Elixir: Xcode CLT, Homebrew, mise; `KERL_CONFIGURE_OPTIONS` set so OTP 28 builds against Homebrew OpenSSL; `mise install` green. |
| T-003 | Pin deps in `mix.exs` (Appendix A): Oban, Req, Rustler, `rustler_precompiled`, `ex_pdfium` (exact), `vix`/`image` (both exact-ish — the vix artefact carries a bundled libvips), `saxy`, `cloak_ecto`, `ecto` (explicitly, `~> 3.14.1`, for UUID v7 helpers), `phoenix_test`, `stream_data`. **Pin nothing from Appendix A's "deliberately absent" list** — two packages earlier drafts told you to pin belong there now, one because it has never existed and one because Ecto 3.14.1 replaced it; read that list before you edit `mix.exs`. OCR belongs to T-019, not here. Verify `mix deps.compile ex_pdfium` downloads a precompiled `aarch64-apple-darwin` NIF rather than building from source, and record which happened (§7.3). **Outcome recorded in ADR 0001: it downloads; no Rust needed for `ex_pdfium`.** |
| T-004 | ∥ Local services: `brew services start postgresql@18`; create the `quire_dev` / `quire_test` databases; apply the two `postgresql.conf` changes from §3.7. |
| T-005 | ∥ `mise run check`: format check, Credo strict, Dialyzer, `mix test`, Sobelow, `mix deps.audit` (vulnerabilities) **and a dependency-licence scan** (GPL/AGPL guard, §3.5 — a separate concern from vulnerabilities), plus T-014's guard and `mise run doctor`. Wire it as a **git pre-push hook**, not a CI service — there is no CI in v1, so the hook is the only thing standing between you and a broken `main`. **The scanner's rules are specified below — a naive "substring GPL fails the build" implementation fails on every run of this repo today.** |
| T-006 | Ecto migrations for §5.1–5.2 — **not `users` or `users_tokens`, which T-200's `phx.gen.auth` migration already created**; T-006 adds only the tables that reference them (settings, licenses, documents, revisions, pages, recents, `document_page_text`). UUID v7 primary keys with `DEFAULT uuidv7()`; `document_page_text.search` is `GENERATED ALWAYS AS (...) STORED` with a GIN index. **Assert no `CREATE EXTENSION` appears in any migration.** |
| T-007 | Ecto migrations for §5.3–5.6 (editing, annotations, forms, security, signing, e-sign, jobs, translation, cloud). |
| T-008 | `Quire.Storage` behaviour + `Storage.Ref` (§7.1). |
| T-009 | `Storage.Web` + the `:filesystem` backend (two-level key fan-out, atomic rename-into-place, zero-copy `with_local_path/2`). Full test suite. Add the `:s3` stub that raises, with its `StorageCase` run `@tag :skip`. |
| T-010 | `Storage.Local` adapter (§12). Same test suite, run against both adapters via a shared `StorageCase`. |
| T-011 | `Quire.Engine` registry + boot self-check skeleton (§7.2): behaviour definitions, telemetry conventions, structured error taxonomy. |
| T-012 | Engine wrapper modules with unit tests against fixtures (no feature code yet): `Render.Pdfium`, `Quire.Pdf` (the `lopdf` NIF — load/save, dictionary read/write, `save_modern` with object + xref streams), `Ocr.Tesseract`, `Ocr.Preprocess` (vix), `Compose` primitives. |
| T-013 | Boot-time engine self-check + version table + graceful per-feature degradation (§7.2). Three states (`ok` / `degraded` / `unavailable`), shared with `mise run doctor` and Settings → About. |
| T-014 | **Guard check**: fail if `File.`, `Path.` (calls, not `Path.t()` typespecs), `System.cmd` or `System.tmp_dir` appear outside `lib/quire/storage.ex`, `lib/quire/storage/`, `lib/quire/engine.ex` and `test/support/`. A Credo custom check is preferable to grep precisely because it can tell a call from a typespec. Runs in `mise run check`. |
| T-015 | Oban config + queues (§7.5) + a `Quire.Workers.Base` with progress reporting and idempotency helpers. Laptop-sized concurrency — all queue limits are **literal constants** in §7.5's table; none are derived from CPU count. `render` and `transform` are fixed at 1 because `ex_pdfium` serialises every call behind a process-wide mutex (§3.3); a core-derived width there buys contention and a second full copy of each document in native memory per blocked worker, and no throughput. Assert the fix in a test, so a later "tune the queues" commit cannot quietly reintroduce it. |
| T-016 | **Build the fixture corpus** (§13) and commit it, including the Office fixtures. |
| T-017 | `Quire.Render` behaviour (§7.3) + `Render.Client` fallback (browser-captured thumbnails). |
| T-018 | `Render.Pdfium` via `ex_pdfium`, pinned exactly. Full callback surface: render, text/spans, search, geometry, **outline read**, attachments, images, page import, page objects, save. **Also owns the crop-origin conversion** (§3.3): every spatial result comes back in the MediaBox frame while `render_page/3` rasterises the CropBox region, and `ExPdfium.bounds_to_pixels/3` does not reconcile them — subtract `boxes.crop`, fall back to `boxes.media` yourself, compose page `/Rotate`, and add a `crop_nonzero_origin.pdf` fixture. Outline *write* is not here; it is `Quire.Pdf.Outline`. |
| T-018a | **`Quire.Pdf` — the Rustler NIF over `lopdf` 0.44.0** (§3.3). Load/save, `save_modern` with object + xref streams, catalog and dictionary mutation, `IncrementalDocument`, `authenticate_password/1`, `Bookmark`/`Outline`. Mark every NIF `DirtyCpu` and bound its inputs (§7.2) — this one is ours, so nobody upstream did it for us. It is compiled from source on every `mix compile`, so **this is the task that makes Rust ≥ 1.91 a hard prerequisite**; verify a clean-checkout build before Gate 0 depends on it. |
| T-019 | `Ocr.Tesseract` via **`image_ocr == 0.2.0`** + `Ocr.Preprocess` via vix. **The engine choice is already made in ADR 0002**; the two packages it rejected are in Appendix A's "deliberately absent" list with the reasons. What remains here is integration: uncomment the dep, wire `Quire.Ocr.Tesseract`, add `brew "pkgconf"` to the `Brewfile` (**mandatory** — `image_ocr`'s Makefile needs `pkg-config`, Xcode CLT does not ship it, and it is a build-only dep of the tesseract formula so pouring the bottle does not install it), and keep `brew "tesseract"` for `osd.traineddata`, which auto-rotate needs and `tesseract-lang` does not provide. `tesseract-lang` (~1.5 GB) can be dropped — `image_ocr` vendors `eng` and fetches packs on demand (T-141). Vendored-vs-Homebrew redistribution is **deferred to T-180**, whose trigger is named in ADR 0002. |
| T-020 | Render + OCR tests against the whole corpus, asserting identical page counts and geometry across code paths, and **running every fixture through every NIF as a crash-fuzz pass**. |
| T-021 | **GATE: verify `ex_pdfium` schedules on dirty CPU schedulers.** Benchmark: render 20 pages concurrently while measuring scheduler utilisation and the latency of an unrelated `:timer.tc` loop. If it stalls, patch or vendor a fork (MIT — painless) and record the decision in an ADR. Run it plugged in — see §14.1. |
| T-022 | **GATE: same verification for the Tesseract and vix NIFs** under a 10-page OCR job. Same remedies. |
| T-023 | `EditSession` GenServer + DynamicSupervisor + Registry (§7.4). |
| T-024 | `Editing.Operation` + one module per op kind with `apply/2` and `invert/1`. Property test: `apply ∘ invert ∘ apply == apply` for all kinds. Update-shaped ops capture their inverse via PG18 `RETURNING OLD.*, NEW.*` in a single statement. |

#### T-005's licence scanner — the rules, because the obvious implementation is wrong

The scan reads each dependency's `deps/<name>/hex_metadata.config`
`licenses` field. Three things about this repo's actual dependency graph
break a naive scanner, and all three must be handled before the hook goes
live:

1. **Not every licence string is SPDX.** `deps/yamerl/hex_metadata.config`
   declares `BSD 2-Clause` — spaces, not hyphens — which no SPDX matcher
   recognises. **Normalise before matching** (case-fold, collapse whitespace
   to hyphens, then map a small alias table), and keep the alias table in the
   repo where it can be reviewed. §3.5's rule stands: a licence field the
   scanner cannot parse is reported **unknown**, never clean.
2. **Not every dependency has Hex metadata at all.** `heroicons` and
   `daisyui` are `github:` deps with no `hex_metadata.config` — `deps/heroicons`
   contains only `.git/` and `optimized/`. A "fail loudly on anything
   unrecognised" rule as usually written therefore **fails on every run**.
   Carve them out explicitly: maintain a short allowlist of non-Hex deps
   keyed by name **and** git tag, each with its licence recorded by hand and
   a comment saying who checked. Adding a name to that list is a review
   event; a *new* non-Hex dep that is not on it still fails the build.
3. **`LGPL-3.0-or-later` must be an explicit allow-entry, not a "GPL" hit.**
   The §3.5 obligation is real but it is not a ban, and a scanner keyed on
   the substring `GPL` fires on it. Match on **normalised whole tokens**, not
   substrings. The allow list is: MIT, Apache-2.0, BSD-2-Clause,
   BSD-3-Clause, **BSD-4-Clause**, ISC, `LGPL-3.0-or-later` (vix's bundled
   libvips only, §3.5), MPL (cairo, inside the same dylib). The deny list is
   `GPL-*` and `AGPL-*` without an `L` prefix. Anything else is unknown → fail.

   **BSD-4-Clause is on that list because `bcrypt_elixir` declares it** —
   `deps/bcrypt_elixir/hex_metadata.config` reads
   `{<<"licenses">>,[<<"BSD-3-Clause">>,<<"ISC">>,<<"BSD-4-Clause">>]}`. It is
   the third of the three deps that break a naive scanner, alongside `yamerl`'s
   non-SPDX string and the metadata-less `github:` sources. Omitting it fails
   the build on the unmodified graph, which is exactly what this section exists
   to prevent. (BSD-4-Clause carries the advertising clause, so it is an
   attribution obligation for T-180, not a distribution problem.)

The scanner also owns one thing a licence field cannot tell it: **the Hex
`licenses` field describes the package, not the binary it downloads.** `vix`
declares `MIT` and ships an LGPL-3.0-or-later dylib. Keep a hand-maintained
note of packages whose *artefact* licence differs from their declared one
(today: `vix`, and `ex_pdfium` for the bundled `libpdfium`), and assert that
list is non-empty rather than trying to derive it.

**Gate 0:** `mise run doctor` is green on a **clean checkout on a second
machine** (or a fresh macOS user account — this is the test that replaces "it
builds in Docker"); both Storage adapters pass an identical test suite; no
migration creates an extension; the journal property test passes for every
op kind; the corpus crash-fuzz pass is clean; `mix ecto.migrate` runs clean
from an empty database with exactly one `users` migration; the seed user logs
in and `on_mount {QuireWeb.UserAuth, :require_authenticated}` rejects an
anonymous session; T-021 and T-022 have written outcomes; **`mise run check`'s
licence scan passes on the unmodified dependency graph** — if it fails on
`yamerl` or `heroicons` it is not configured, it is broken.

---

### Phase 1 — Application shell (~1.5 weeks)

| ID | Task |
|---|---|
| T-025 | Design tokens in `app.css` (§8.4). Delete the daisyUI dep and config and rewrite **all** generated markup in one pass — `core_components.ex`, the layouts, and the `phx.gen.auth` templates from T-200 (login, registration, confirmation, session, settings). Nothing daisyUI-classed survives (§3.1). |
| T-026 | `TitleBar` component (§8.2) with QAT and window controls (hidden on web). |
| T-027 | ∥ QAT customise menu, persisted to `user_settings.qat_items`. |
| T-028 | `MenuBar` with all **11** tabs, active-dot styling, `Activate now`, help, gear. |
| T-029 | Ribbon primitives: `ribbon_group`, `ribbon_button`, `ribbon_split_button`, `ribbon_toggle`, `ribbon_separator`, `zoom_control` (§8.3). |
| T-030 | ∥ `dropdown_menu`, `modal`, `floating_bar`, `panel`, `tool_tile`, `doc_card`, `progress_toast`, `color_picker`, `font_picker`, `page_thumb`. |
| T-031 | `WorkspaceLive` shell: rails, collapsible panels, document tabs, status bar (§8.1). |
| T-032 | Multi-document tab strip: open, switch, close, close-with-unsaved-prompt, reorder. |
| T-033 | Keyboard map (§8.5) with a colocated hook; a discoverable shortcuts modal. |
| T-034 | ∥ OPFS cache hook (§7.1) — put/get/evict by LRU with a quota guard. |
| T-035 | `HomeLive` (§10.1): tile grid, Recent panel, sort/view toggles, drag-drop, empty state, FABs, **and the Customize tile** (reorder/show/hide, persisted). |
| T-036 | Backstage overlay (§10.2): left rail, source column, Computer pane with the adapter split, Browse via LiveView uploads. |
| T-037 | **Save / Save as / Save optimized / Exit** (§7.4 "Save", §10.2): materialise the journal into a revision, dirty-state tracking, the disabled-Save state, unsaved-changes prompts on close/exit, and the `Ctrl+S` / `Ctrl+Shift+S` bindings. Save optimized chains a compress job and reports the size delta. |
| T-198 | QAT **email** and workspace **share** controls (§8.2): compose-and-attach modal via Swoosh; expiring share links with optional password and a revocation list. |
| T-038 | Accessibility pass: roving tabindex on the ribbon, tablist semantics, focus traps, aria-labels. axe-core clean. |
| T-039 | Visual regression baselines for every tab at 1280/1600/1920 px. |

**Gate 1:** every tab renders its (non-functional) ribbon at pixel-parity
with the reference layout; keyboard-only navigation reaches every control;
axe reports zero critical issues.

---

### Phase 2 — Viewer and the View tab (~1.5 weeks)

| ID | Task |
|---|---|
| T-040 | Vendor pdf.js 6.1.200: esbuild ESM config, worker as a separate entry, copy `cmaps/`, `standard_fonts/`, `iccs/`, `wasm/` to `priv/static/vendor/pdfjs/`. Node comes from mise; commit `package-lock.json` and add a `mise run assets.vendor` task so the copy step is reproducible. |
| T-041 | `document_controller.ex` with HTTP range support, ETag, and auth — `QuireWeb.UserAuth.require_authenticated_user` (generated in T-200) plus an owner check against `documents.owner_id`. |
| T-042 | `PdfViewerHook` wrapping `PDFViewer` + `EventBus` + `PDFLinkService` (§3.2). |
| T-043 | `geometry.js` + the Elixir twin (§14.3) with the round-trip property test. |
| T-044 | Document open pipeline (§10.3) including encryption detection and the password prompt. |
| T-045 | Thumbnail render worker + `document_pages.thumbnail_ref` caching. |
| T-046 | Thumbnails panel (virtualised) with current-page sync. |
| T-047 | ∥ Bookmarks panel: read the outline via `Render.Pdfium`, navigate, add/rename/delete/reorder via **`Quire.Pdf.Outline`** — PDFium's public API is getters only (§3.3), and `@cantoo/pdf-lib` has no bookmark API at all, so the five `doc.bookmark_*` ops stay **server-authoritative** and their §7.4 undo payloads are unchanged. Depends on T-018a. |
| T-048 | ∥ Search panel via `PDFFindController`: highlight-all, match case, whole word, result list, ↑/↓ navigation. Above a page-count threshold, fall back to the server-side `document_page_text` index (§5.2) with `websearch_to_tsquery`, mapping hits back to page + rect via the stored spans. The two paths must present identically. |
| T-049 | ∥ Attachments panel: list, preview, extract, add, remove. |
| T-050 | ∥ Layers (OCG) panel. |
| T-051 | View tab: scroll/spread modes, fit modes, zoom control, `Ctrl+scroll`. |
| T-052 | Fullscreen mode. |
| T-053 | Side-by-side split with synchronised scroll. |
| T-054 | Rotate view (non-destructive) with a tooltip disambiguating it from Page → Rotate. |
| T-055 | Snapshot: marquee → 2× render → clipboard + save PNG. |
| T-056 | Read aloud via the Web Speech API with word highlighting. |
| T-057 | Page navigation pill with an editable page input. |
| T-058 | Performance pass against §14.1 using `500_pages.pdf` and `50mb_images.pdf`. |
| T-199 | ∥ Playwright set-up: `@playwright/test` + Chromium, a `mise run e2e` task, and the first end-to-end test (open a fixture, assert page 1 renders). Baselines under `test/visual/darwin-arm64/` (§13). |

**Gate 2:** every corpus fixture opens and renders correctly, including CJK,
RTL, rotated and non-zero-origin-crop pages; the performance budget is met;
the server-side search fallback returns the same hits as the client path on
`500_pages.pdf`.

---

### Phase 3 — Page tab (~1 week)

| ID | Task |
|---|---|
| T-059 | Thumbnail workspace: virtualised grid, multi-select, zoom slider, grid/single toggle. |
| T-060 | Drag-to-reorder with an insertion caret; optimistic `page.move`. |
| T-061 | `TransformWorker` + PDFium page-import helpers (the splice primitive every op below uses). |
| T-062 | Insert (blank / from file / clipboard / scan). |
| T-063 | ∥ Extract, Replace, Reverse, Delete, Rotate (persistent). |
| T-064 | ∥ Background (colour / image / PDF) via page objects. |
| T-065 | ∥ Size and Margin (box manipulation + content transform). Box *set* is not bound by `ex_pdfium` today but **is** reachable through pdfium-render's `boundaries_mut()`, so this is **not** doubly blocked: it ships with the D4 upstream PR (§3.3), not with a rewrite. Form XObject / place-a-page-on-a-page rides the same PR, which is why T-064's "background: another PDF" needs no rasterise fallback. |
| T-066 | Export images (PDFium image extraction → ZIP). |
| T-067 | Page crop (interactive, CropBox-only) + Remove crop. |
| T-068 | Wire every page op through the journal with working undo. |

**Gate 3:** a 200-page document can be reordered, cropped and re-cropped
with undo at every step, and the result opens correctly in Acrobat.

---

### Phase 4 — Create & Convert (~2 weeks)

> This phase contains the native OOXML layer — the largest single piece of
> in-house engine code in the project (§9.2, R-03). Build the reader's
> layout model and the HTML bridge first; every converter below consumes it.

| ID | Task |
|---|---|
| T-069 | `Office.Layout` intermediate model + `Office.Reader` for **docx** (ZIP + Saxy: styles, paragraphs, tables, images, lists) → HTML. |
| T-070 | ∥ Extend the reader to **xlsx** and **pptx** (cell grids, sheets; slide shapes, text frames, images). |
| T-071 | ∥ Extend the reader to **odt/ods/odp** and **rtf** (simpler formats, same target model). |
| T-072 | `ConvertWorker` + chromic_pdf integration: HTML → PDF via system Chromium, explicit executable path, job-level timeout, SSRF guard shared with T-077. Serial tests only (§13). |
| T-073 | File to PDF (all listed input formats: Office via reader → HTML → Chromium; txt/md/csv direct to HTML; images via vix → PDFium). |
| T-074 | ∥ PDF to Word / Excel / PowerPoint via `Office.Writer.*` (spans → OOXML), with the "run OCR first" prompt. |
| T-075 | ∥ PDF to Image (DPI, format, range, ZIP) via PDFium + vix. |
| T-076 | ∥ PDF to TXT (layout + reading-order modes). ∥ PDF to RTF (labelled low fidelity). |
| T-077 | URL to PDF via chromic_pdf, with the SSRF guard. |
| T-078 | PDF to HTML (render + positioned text spans, single self-contained file). |
| T-079 | Clipboard to PDF. |
| T-080 | Scan to PDF (camera capture, deskew via vix, contrast). |
| T-081 | Merge wizard (reorder, per-file ranges, **bookmark AND form handling**) via PDFium page import. ⚠️ `append/2` and `extract_pages/2` **drop `/AcroForm` and `/Outlines`** while leaving widget annotations behind, so the naive output *looks* like a form and is not one — the documented "keep forms" option is unimplementable through `append/2` alone. `Quire.Pdf.fixup_after_append/3` and `Quire.Pdf.fixup_after_extract/2` combine AcroForm and outline re-attachment (`Quire.Pdf.AcroForm.rebuild_fields/1` + `Quire.Pdf.Outline.transfer/3` / `filter_for_pages/2`) in a single call (§3.3). |
| T-082 | Split (all five modes in §9.2) → ZIP. |
| T-083 | Compress with presets (image recompression pipeline) and a before/after preview. **Rebuild is object streams + xref streams via `Quire.Pdf`, and produces no linearization** — neither PDFium nor `lopdf` can linearize, so the acceptance criterion is a measured size reduction, never a `/Linearized` dictionary (§9.2). |
| T-084 | **PDF to PDF/A** — `Quire.PdfA` best-effort conversion + the built-in structural conformance report, shown to the user either way, labelled "best-effort" (§9.2). |
| T-085 | New ▾ (blank, template, from file/clipboard/scanner). |
| T-086 | Operation progress UI: status strip + toasts driven by PubSub. |
| T-087 | Batch runner + recipe builder (Home tile). |

**Gate 4:** every conversion runs end-to-end with live progress; the Office
fixtures convert to PDF with layout recognisably intact (headings, tables,
lists, images in place — pixel-perfection is *not* the bar, see R-03); a
50 MB document converts without exceeding the memory budget; failures
produce actionable messages.

---

### Phase 5 — Edit tab (~2 weeks)

| ID | Task |
|---|---|
| T-088 | `DocMutateHook` over `@cantoo/pdf-lib` 2.7.4. |
| T-089 | Add text (Add mode) via `FreeTextEditor` + committed text objects. |
| T-090 | Floating text format bar, full control set (§9.5). |
| T-091 | Edit mode: identify existing runs via PDFium spans; rewrite content streams via `Compose`; refuse gracefully on non-embedded/subset fonts with an OCR suggestion. |
| T-092 | Insert image (with server-side format normalisation to PNG/JPEG via vix). |
| T-093 | Link tool + **Add Action** modal, all action types; JS actions **off by default**. |
| T-094 | ∥ Format painter. ∥ Select text mode. |
| T-095 | Page number stamping (`Compose` + PDFium page objects). |
| T-096 | ∥ Watermark (text + image, all options). ∥ Header and footer with tokens. |
| T-097 | ∥ Bates numbering with cross-merge continuity. |
| T-098 | Remove page marks (tracked marks only; explain the limitation). |
| T-099 | Spell check (browser-native interactive + the pure-Elixir document report, §9.5). |
| T-100 | ∥ Ruler with guides. ∥ Grid with snap. |
| T-101 | Coalescing rules for typing/styling ops (§7.4). |

**Gate 5:** a 50-operation edit session undoes and redoes cleanly; output
renders identically in Acrobat, Chrome and Preview.

---

### Phase 6 — Comment tab (~1.5 weeks)

| ID | Task |
|---|---|
| T-102 | `AnnotEditHook` driving pdf.js's editor layer **through `PDFViewer.annotationEditorMode` + `annotationEditorParams` and the EventBus** — do not instantiate `AnnotationEditorLayer` yourself (§9.6). |
| T-103 | Text markup: highlight, underline, strikethrough, squiggly. |
| T-104 | ∥ Sticky notes with icon set and reply threads. |
| T-105 | ∥ Ink/pencil with coalesced pointer events and an eraser. |
| T-106 | ∥ Shapes: line, arrow, double-arrow, dimension, oval, rectangle, polygon, cloud, polyline. |
| T-107 | ∥ Stamps (built-in + custom). ∥ File attachment annotations. ∥ Free-text callout. |
| T-108 | Measure tools with scale calibration. |
| T-109 | Whiteout **with the mandatory redaction warning**. |
| T-110 | Comments panel: grouping, filtering, replies, resolved status. |
| T-111 | Export/import comments (FDF, XFDF, CSV, summary PDF — all generated in Elixir). |
| T-112 | Compare: text diff + visual diff (PDFium rasters, Elixir pixel diff) in side-by-side view with a change list. |
| T-113 | Round-trip test: annotate here → open in Acrobat → verify → re-open here. |

**Gate 6:** all annotation types round-trip losslessly; ink is smooth at
120 Hz; the whiteout warning is unmissable.

---

### Phase 7 — Fill & Sign + Forms (~1.5 weeks)

| ID | Task |
|---|---|
| T-114 | Signature capture: draw (smoothed), type (script fonts), upload (background removal). Saved appearances. |
| T-115 | Placement, resize, move; commit as flattened XObjects. |
| T-116 | Initials, signer's name, signing date. |
| T-117 | Fill & Sign palette: text, crossmark, checkmark, filled dot, line. |
| T-118 | Auto-detect fields (AcroForm + heuristic box detection) and "Fill automatically". |
| T-119 | Forms: field creation tools for all seven types. |
| T-120 | Field properties dialogs (per type, full option set). |
| T-121 | Field list panel with drag tab-order editing. |
| T-122 | Highlight fields toggle. |
| T-123 | Form data import/export (FDF, XFDF, JSON, CSV) + flatten (PDFium). ⚠️ Flatten is `/AP`-only: value writes need `Quire.Pdf.AcroForm.generate_appearances/1` or `render_page/3` instead. |
| T-124 | Reset form. |
| T-125 | Auto-create fields from a scanned form. |
| T-126 | Acrobat + Chrome compatibility test for authored forms. |

**Gate 7:** a form authored here fills and submits correctly in Acrobat and
Chrome; a signature placed on a rotated, cropped page survives save/reload.

---

### Phase 8 — Secure (~2 weeks)

> This phase contains the in-house cryptographic code (`Quire.Pades` and
> `Quire.SecurityHandler`). The acceptance bar is interoperability
> against Acrobat and the reference fixtures, not self-consistency (R-04).

| ID | Task |
|---|---|
| T-127 | `SecurityHandler`: AESV2/AESV3 encryption + permission flags per ISO 32000-2 §7.6. Password handling: never logged, assigns zeroed. Verify by opening output in Acrobat and by decrypting the encrypted fixtures. |
| T-128 | Decrypt / remove protection (with the owner password). |
| T-129 | `Pades.Cms` + `Pades.Pkcs12`: keystore parsing, CMS detached signature construction over byte ranges. Unit-test against published RFC 5652 vectors. |
| T-130 | `Pades` signing flow: visible field placement, PAdES B-B and B-T (`Pades.Tsa` RFC 3161 client over Req), certificate management UI. |
| T-131 | `Pades` validation: chain verification, timestamp check, difference analysis; the Signatures panel (status, signer, chain, timestamp). |
| T-132 | B-LT: DSS/VRI appending for long-term validation. |
| T-133 | Redaction marking (rectangle + text selection) with reason codes and overlay text. |
| T-134 | **Apply redaction** — PDFium object-removal path with the rasterise-and-replace fallback, plus the mandatory post-hoc text-extraction verification. Fail the job if redacted strings survive. |
| T-135 | Search and redact with presets (SSN, card, email, phone, IBAN) and per-hit review. |
| T-136 | Remove metadata with a before/after table. |
| T-137 | Sanitize: enumerate via PDFium inspection + Elixir object walk, present a checklist, rewrite. |
| T-138 | Regression suite: `signed_pades.pdf`, `encrypted_*.pdf`, plus signatures and encrypted files produced by this app, cross-checked in Acrobat. |

**Gate 8:** applied redactions are unrecoverable by text extraction, copy or
image analysis; encrypted output opens in Acrobat with the expected
restrictions; **a signature applied here validates in Acrobat, and every
fixture signature validates here.**

---

### Phase 9 — OCR (~1 week)

| ID | Task |
|---|---|
| T-139 | `OcrWorker` running the full in-BEAM pipeline (§9.10): PDFium rasterise → vix preprocess → Tesseract NIF → sandwich text layer via `Compose`. |
| T-140 | OCR options UI (languages, mode, deskew, rotate, clean, optimise). |
| T-141 | tessdata management: on-demand download, cache, disk-usage display. |
| T-142 | Per-page confidence reporting + a low-confidence page list with re-run. |
| T-143 | External image OCR. |
| T-144 | Scan-and-recognise combined flow. |
| T-145 | Auto-prompt "this document has no text layer — run OCR?" on open and before text-dependent operations. |

**Gate 9:** `scanned_300dpi.pdf` becomes searchable in Chrome's viewer; page
images are visually unchanged; throughput meets §14.1; the §14.1
scheduler-stall budget holds while `:ocr` and `:render` are both saturated.

---

### Phase 10 — E-Sign (~2 weeks)

| ID | Task |
|---|---|
| T-146 | Envelope data model + state machine with guarded transitions. |
| T-147 | Request-signature wizard (signers, field placement per signer, message, expiry, reminders). |
| T-148 | Email delivery (Swoosh) with templates; bounce handling. |
| T-149 | Public signer LiveView `/sign/:token`: identity confirmation, consent disclosure, review, required-field enforcement, sign, receipt. Rate-limited, single-purpose expiring tokens. |
| T-150 | Sequential and parallel signing orders. |
| T-151 | Audit event capture (all events in §9.9) + certificate-of-completion PDF (PDFium page objects). |
| T-152 | Apply a document-level PAdES B-LT signature on completion (§9.7). |
| T-153 | Inbox: Sent and Received views, resend, void, download. |
| T-154 | Manage signers address book. |
| T-155 | Reminder + expiry scheduled jobs. |

**Gate 10:** a 3-signer sequential envelope completes end-to-end **through a
tunnel** (§1.2); the audit certificate matches the recorded events;
tampering with the completed document fails validation.

---

### Phase 11 — Translate (~1 week)

| ID | Task |
|---|---|
| T-156 | `Translation.Provider` behaviour + one real implementation + `Provider.Null` (the default — returns source text with a "translation disabled" banner, so a fresh clone runs and the suite costs nothing). |
| T-157 | Translate document in all three modes (overlay, sidecar, replace) via `Compose`. |
| T-158 | Shrink-to-fit + overflow reflow handling with a review list. |
| T-159 | Selection translate popup; translate comments; glossary. |
| T-160 | Cost estimation + caching in `translation_cache` by `sha256(text)+langs`. |
| T-161 | Consent and provider disclosure in Settings (§11.3): which provider, what leaves the machine, retention. Translation is the only v1 feature that sends **document content** to a third party — the setting defaults to off (`Provider.Null`) and the tab says so plainly. |

**Gate 11:** translation of a 20-page document preserves layout acceptably
and flags every overflowed region in the review list; with `Provider.Null`
configured the tab renders, explains itself and makes no network call; the
cache prevents a re-translation of unchanged text.

---

### Phase 12 — Accounts, licensing, cloud (~1 week)

| ID | Task |
|---|---|
| T-162 | Accounts polish on top of T-200's generator output: confirmation-flow copy, token-expiry handling, sudo mode applied to the Secure tab and certificate management, and the §11.1 avatar notification dot. The generator, its migration and its daisyUI cleanup are Phase 0 work (T-200, T-025). Phoenix 1.8.9 already generates confirmation and sudo mode — this task is coverage and copy, not construction. |
| T-163 | ∥ Optional TOTP 2FA. |
| T-164 | Licensing tiers + `allows?/2` + `<.gated>` component; enforce in component, event handler **and** worker. |
| T-165 | `Activate now` modal + key validation + trial expiry handling. |
| T-166 | Settings screens (§11.3) including the engine version table. |
| T-167 | Cloud connectors: Google Drive, Dropbox, OneDrive, Box OAuth; S3/WebDAV manual. Tokens encrypted with `cloak_ecto`. (The S3 *connector* is somewhere the user's files come from — do not wire it into the `Storage` *backend*; those are different seams.) |
| T-168 | Cloud file browser in the backstage Computer pane. |
| T-169 | Recent documents: pin, remove, clear all, sort, thumbnails. |
| T-170 | Properties dialog (all six sections in §10.2) with editable metadata. |
| T-171 | Print + Print selection (flattened print PDF → iframe → `window.print()`). |
| T-172 | Retention job: prune old revisions and scratch storage. |

**Gate 12:** a Standard-tier user cannot invoke a Premium-tier worker even
by hand-crafting a LiveView event; cloud round-trip works for at least one
provider.

---

### Phase 13 — Desktop packaging (~1.5 weeks)

| ID | Task |
|---|---|
| T-173 | Add `src-tauri/`, Tauri 2.11.x, `beforeBuildCommand` release step, `bundle.resources`. Rust comes from mise, already present since Phase 0 — do not add rustup separately, and do not let Tauri's installer script add a second toolchain. |
| T-174 | ElixirKit wiring: PubSub listen, spawn release, `ready:<url>`, window creation, `on_exit` → `System.stop()`. |
| T-175 | Port + `SECRET_KEY_BASE` injection from Rust; `runtime.exs` reads them. |
| T-176 | `remote.urls` capability for **`http://localhost:*`** (not `127.0.0.1` — §12.1 step 5); dialog + fs permissions. |
| T-177 | Localhost auth plug (32-byte per-run token, `secure_compare`, ETS sessions). Keep `check_origin: true`. |
| T-178 | Switch to `Storage.Local`; wire `pick_open`/`pick_save` to the Tauri dialog plugin via a hook. |
| T-179 | Real Local Folders + drive listing in the backstage Computer pane — **no LiveView changes**, adapter only. Verify this. |
| T-180 | Native-library redistribution: verify the PDFium and libvips dylibs travel inside their NIF artefacts; make Tesseract + tessdata redistributable per ADR 0002; `otool -L` every binary and confirm nothing links back into `/opt/homebrew`. Also ship the **complete LGPL-3.0-or-later licence set** for everything statically inside `libvips-cpp.8.18.3.dylib` (§3.5) — the artefact we consume contains no licence files — and confirm cairo's exact MPL version while you are in there. **Budget more than a day: this is bigger than the plan's original estimate.** The `image_ocr` dylib closure alone is 14 libraries, the exit is a per-triple precompile matrix rather than a static link on macOS, and **T-183 is blocked independently of this task** — `image_ocr` does not build on Windows at all, so a macOS static link does not unblock it. |
| T-181 | Window controls in the title bar wired to the shell. |
| T-182 | macOS: entitlements (`allow-jit`, `allow-unsigned-executable-memory`, `allow-dyld-environment-variables`, `disable-library-validation`), codesign step, notarisation. |
| T-183 | ∥ Windows: MSI/NSIS, code signing, WebView2 bootstrap. |
| T-184 | ∥ Linux: deb + AppImage. **Test the ribbon and pdf.js on webkit2gtk** — this is where CSS breaks. |
| T-185 | Auto-update (Tauri updater + signed manifests). |

**Gate 13:** the app builds and runs on all three platforms; opening a file
from a real folder works; **no LiveView or context code changed in this
phase** (if it did, §7.1 was violated — fix that instead).

---

### Phase 14 — Hardening (~1.5 weeks)

| ID | Task |
|---|---|
| T-186 | Full a11y audit; keyboard-only walkthrough of every feature; screen-reader pass. |
| T-187 | Dark mode completion. |
| T-188 | i18n scaffolding (Gettext) + one non-English locale to prove it. |
| T-189 | Load test on *this* machine: 20 concurrent conversions, 50 concurrent viewers. Tune the §7.5 queue numbers against real measurements and record them. Assert the §14.1 scheduler-stall budget while `:ocr` and `:render` are both saturated. |
| T-190 | Security review: dependency audit, SSRF, upload validation (magic bytes, not extensions), path traversal, rate limits, CSP. Also: Sobelow clean, `.mise.local.toml` in `.gitignore`, and a history sweep for any secret that ever got committed. |
| T-191 | Telemetry dashboards: engine durations, queue depth, render latency, error rates. LiveDashboard is enough locally; do not stand up a metrics stack for one machine. |
| T-192 | Error taxonomy: every failure maps to a user-facing message + a docs link. |
| T-193 | Onboarding tour + per-tab help. |
| T-194 | Documentation: README (with the §3.6 bootstrap), ARCHITECTURE.md, ADR log, runbook. The README's setup section is tested by doing it on a fresh macOS user account — if it takes more than the bootstrap sequence in §3.6.1, fix the setup, not the README. |
| T-195 | Visual regression across all tabs, both themes, three widths. Three *platforms* only once Phase 13 exists; until then `darwin-arm64` baselines are the whole suite (§13). |
| T-196 | ∥ Reproducibility check: clone into a fresh directory on a second machine (or a new macOS user account), run the §3.6.1 bootstrap, `mise run doctor`, `mise run check`, `mise run e2e`. Everything green with no manual intervention. Without a container image, this is the only real evidence that the `mise.toml` + `Brewfile` contract holds. |
| T-197 | ∥ Final NIF crash-fuzz sweep over the entire corpus (§13) plus a 24-hour soak: OCR + render + convert queues saturated in a loop, asserting zero VM crashes and zero scheduler-stall budget violations. |

**Gate 14:** ship.

---

## 16. Appendices

### Appendix A — Hex dependencies

⚠️ **`mix.exs` is authoritative, not this table.** T-003 pinned every
requirement below against the live Hex registry and amended the plan where
they disagreed; the versions here are the amended ones. If they ever diverge
again, `mix.exs` wins and this table is the thing that is wrong.

| Dependency | Version | Purpose |
|---|---|---|
| phoenix | ~> 1.8.9 | Web framework |
| phoenix_ecto | ~> 4.7 | Phoenix ↔ Ecto integration |
| ecto | **~> 3.14.1** | Declared explicitly for UUID v7. The *helpers* §3.7 uses (`to_datetime/1`, `to_unix/2`, `version/1`) landed in 3.14.1, not 3.14.0 — `ecto_sql`'s floor alone admits a version that cannot do this |
| ecto_sql | ~> 3.14 | Migrations, SQL adapter |
| postgrex | ~> 0.22 | Database driver (speaks PG18 unchanged) |
| bcrypt_elixir | ~> 3.3 | Password hashing — added by `phx.gen.auth` in T-200 |
| phoenix_html | ~> 4.3 | HTML |
| phoenix_live_reload | ~> 1.6 (dev) | Live reload |
| phoenix_live_view | ~> 1.2.7 | LiveView + colocated hooks. Floor is 1.2.7 per §3.1; do not relax it |
| phoenix_live_dashboard | ~> 0.8.7 | Telemetry UI (T-191) |
| esbuild, tailwind | ~> 0.10 / ~> 0.5 (dev) | Assets (darwin-arm64 standalone binaries) |
| heroicons | v2.2.0 (git, sparse) | Icons (§8.4). **No Hex metadata — see T-005's scanner carve-out** |
| swoosh | ~> 1.26 | Mail (QAT email, e-sign envelopes) |
| req | **~> 0.7.1** | HTTP (URL fetch, TSA, cloud, translate). 0.7.0 was breaking; `~> 0.7` is not a bound — see §3.1 |
| telemetry_metrics, telemetry_poller | ~> 1.1 / **~> 1.3** | Telemetry |
| gettext | **~> 1.0** | i18n (T-188). gettext 1.0 has shipped; the old `~> 0.26` predates it |
| jason | ~> 1.4 | JSON |
| dns_cluster | **~> 0.2.0** | Inert locally (§1.2). The generator's bound is tighter than `~> 0.1` and correct |
| bandit | **~> 1.12** | HTTP server |
| oban | **~> 2.23** | Jobs (§7.5) |
| ex_pdfium | == 0.5.1 | PDFium NIF — exact pin, T-021 (§3.3) |
| rustler | ~> 0.38, `runtime: false` | Builds `Quire.Pdf`; also the `EXPDFIUM_BUILD=1` fallback and Tauri. **Sets the Rust 1.91 floor** |
| rustler_precompiled | **~> 0.8.4** | Performs the `ex_pdfium` artefact download. `ex_pdfium` asks for `~> 0.8`, which floats to 0.9.0 — hold the 0.8 line (ADR 0001) |
| vix | **== 0.40.0** | libvips NIF. Exact, because the artefact carries a bundled libvips — a minor bump swaps a native library. See §3.5 on its licence |
| image | **~> 0.72.0** | vix's principal consumer, pinned to the same granularity: letting it float means a future release that raises its vix floor makes the pair hard-unsatisfiable |
| saxy | **~> 1.6** | Fast XML parsing for the OOXML reader. The old `~> 1.x` is **not valid Mix syntax** and raises `Version.InvalidRequirementError` |
| elixlsx | ~> 0.6 | xlsx writer (MAY — a native writer is the alternative, T-074) |
| chromic_pdf | == 1.17.1 | URL/HTML → PDF via system Chromium (§3.3). **`print_to_pdf` only** — its PDF/A path shells out to Ghostscript (AGPL-3.0), which §3.4 forbids; PDF/A is `Quire.PdfA` (T-084) |
| cloak_ecto | ~> 1.3 | Cloud OAuth tokens at rest (§5.6) |
| benchee | ~> 1.5 (dev/test) | Benchmarks (T-021, T-058, T-189) |
| phoenix_test + lazy_html | ~> 0.11.1 / ~> 0.1.12 (test) | LiveView testing |
| stream_data | ~> 1.4 (dev/test) | Property tests (§13) |
| credo, dialyxir, sobelow, mix_audit | ~> 1.7 / ~> 1.4 / ~> 0.14 / ~> 2.1 (dev/test) | `mise run check` (T-005) |

**Owned by T-019, deliberately not pinned yet:**

| Dependency | Version | Purpose |
|---|---|---|
| image_ocr | `== 0.2.0` | Tesseract NIF (ADR 0002). Commented out in `mix.exs` on purpose: uncommenting makes a Homebrew Tesseract a hard build prerequisite for every developer, and that should land with the integration, not ahead of it |

**Deliberately absent, and why — do not "helpfully" re-add these:**

- **`tesseract_elixir` — it does not exist and never has.** This is the one
  and only place in the plan that names it, deliberately: earlier drafts had
  rows for it in this appendix, in Appendix D, in T-003 and in T-019, and
  `mix hex.info` returns "No package with name tesseract_elixir" for all of
  them. It was **deleted, not version-corrected**. ADR 0002 replaced it with
  `image_ocr`. Do not reintroduce the name anywhere but this bullet.
- **`tesseract_ocr`** — the highest-download "tesseract" package on Hex, and
  disqualified: it shells out via `System.cmd("tesseract", ...)`, which §3.4
  forbids outright.
- **`tesserax`** — a real MIT in-process NIF, but it reports **no per-word
  confidence at all**, which §9.10 requires, and it has a one-byte heap
  overflow on every recognition. Either alone settles it.
- **`uniq`** — deleted per ADR 0001/T-003, and likewise named only here.
  Ecto 3.14.1 supplies UUID v7 generation, timestamp extraction **and** a
  monotonic precision mode that this package does not have at all. Adding it
  would mean two UUID implementations with different ordering guarantees.
- **daisyUI** — **not absent: present in `mix.exs` and `deps/`**, pinned at
  `v5.5.20` (MIT). T-025 owns deleting the dep, the `@plugin` blocks in
  `app.css`, and every daisyUI-classed element in one pass. Until then it
  lingers as generated scaffolding; under the appendix's own precedence rule
  (`mix.exs` is authoritative), the old "deliberately absent" entry was
  wrong.

### Appendix B — Local toolchain files

These files, together with `mix.lock` and `package-lock.json`, are the
entire reproducibility contract (§3.6.2). **Commit all of them.** Contents
specified here; write them exactly.

#### B.1 `mise.toml`

- `[tools]`: `erlang = "28.1"`, `elixir = "1.20.2-otp-28"`,
  `node = "24"` (asset vendoring + Playwright only), **`rust = "1.91"`** —
  set by rustler 0.38.0's declared `rust-version`, which cargo enforces with
  no override. Rust is **on the happy path**, not a fallback: `Quire.Pdf`
  (§3.3) compiles from source on every `mix compile`. **No Java, no Python.**
- `[env]`: `MIX_ENV`, `ERL_AFLAGS` (shell history), `QUIRE_DATA_DIR`
  pointing at `<repo>/_data/storage`, and `KERL_CONFIGURE_OPTIONS` per §3.6.3.
- Tasks: `setup` (hex/rebar install, deps.get, ecto.create+migrate, npm ci,
  assets.setup, assets.vendor), `doctor` (runs the §7.2 self-check via
  `mix run --no-start`), `server` (`ulimit -n 8192` + `iex -S mix
  phx.server`), `test` (test DB + `mix test` + the serial pass), `e2e`
  (Playwright), `check` (the T-005 suite, depends on `doctor`),
  `assets:vendor` (copies pdf.js runtime assets into `priv/static`, T-040),
  `assets:resign` (ad-hoc re-signs mix-downloaded binaries, §3.6.6).
  Namespaced task names use mise's `:` separator, not `.` — mise truncates a
  dotted name at the dot when listing, so `assets.vendor` and `assets.resign`
  both display as `assets`.

`.mise.local.toml` is **gitignored** and holds machine-specific or secret
values: `TRANSLATION_API_KEY`, `TSA_URL`, `CHROME_EXECUTABLE` (if not
auto-detected), `PGUSER` (only if the Postgres role is not `$USER`).

#### B.2 `Brewfile`

Deliberately tiny — the whole point of this architecture:

| Entry | Why |
|---|---|
| `brew "postgresql@18"` | Database (18.4) |
| `brew "openssl@3"` | kerl needs it to build OTP crypto |
| `brew "autoconf"` | kerl |
| `brew "tesseract"` | **Required** — ADR 0002 chose a system Tesseract (5.5.3) + Leptonica for v1, revisited at T-180. Keep the **base** formula specifically: it ships `osd.traineddata`, which §9.10's auto-rotate needs and `tesseract-lang` does not provide |
| `brew "pkgconf"` | **Required, and a Gate 0 blocker if omitted.** `image_ocr`'s Makefile shells out to `pkg-config`; Xcode CLT does not ship it, and pkgconf is a *build-only* dependency of the tesseract formula (`brew deps --include-build tesseract` lists it, `brew deps tesseract` does not), so pouring the bottle does not install it. On a clean second machine — exactly the machine Gate 0 tests — the build dies with `ERROR: image_ocr requires tesseract >= 5.0.0 (found none)` |
| ~~`brew "tesseract-lang"`~~ | **Dropped** (~1.5 GB). `image_ocr` vendors `eng` tessdata_fast in `priv/` and fetches further packs on demand, so T-141 can install languages without the up-front cost. Re-add only if `osd` is ever unavailable from the base formula |
| `cask "chromium"` | URL→PDF / Office→PDF renderer; alternatively reuse an installed Chrome — either way the path is explicit config, never discovery (§3.6.6) |

Pin with `brew bundle --no-upgrade` so an unrelated `brew upgrade` does not
silently move a native library underneath you; `mise run doctor` is what
actually catches it when it happens anyway. **Nothing else may be added to
this file without an ADR** (§3.4).

#### B.3 What T-013 must assert

The doctor table (all asserted at boot and by `mise run doctor`):

| Component | Check | Expect |
|---|---|---|
| PostgreSQL | version query | `18.x` |
| ex_pdfium / PDFium | NIF info call + 1-page fixture render | loads, exact pinned version, render succeeds |
| Tesseract NIF | NIF info call + 1-line image OCR | loads, version recorded, text recognised |
| vix / libvips | NIF info call + 1-image transcode | loads, version recorded |
| Chromium | resolved from **config**, `--version` | found or feature-degraded with a clear message |
| Dirty schedulers | T-021/T-022 micro-benchmark | no measurable stall |
| File descriptors | `ulimit -n` | ≥ 8192 in task env |

### Appendix C — Risk register

| ID | Risk | Impact | Mitigation |
|---|---|---|---|
| **R-01** | `ex_pdfium` is young and may block BEAM schedulers or crash the VM | High | T-021 gate; exact pin; vendor/patch a fork (MIT); corpus crash-fuzz in Phase 0 and T-197; `Render.Client` fallback for thumbnails. **Note the "patch the MIT fork" escape does not reach every gap:** outline write and linearizing save are absent from PDFium's own public C headers, so no fork produces them (§3.3) — that is why `Quire.Pdf` exists and why linearization was dropped rather than deferred |
| **R-01a** | **`image_ocr` is very young for something load-bearing** — 2 releases, 160 all-time downloads, 3 GitHub stars. The maintainer is Kip Cole (`image`, the ex_cldr suite), which is real credibility, but this specific package has near-zero field exposure | Medium | `== 0.2.0` exact pin, deliberately; the package is ~290 lines of C++ and forkable if abandoned; ADR 0002 names five explicit triggers for revisiting, of which "goes unmaintained or archived" is one |
| **R-01b** | **PDFium throughput is capped at one call VM-wide** by `ex_pdfium`'s process-wide `PDFIUM_LOCK`, and the T-058 benchmark plus the Gate 2 bar were both set without knowing this | Medium | §7.2 declares the concurrency limit; §7.5 fixes `render`/`transform` at 1 and T-015 asserts it; T-058 benchmark expectations and Gate 2 bar re-derived against a serialised engine. Escapes, in order of cost: the D4 fork with per-document locks *if* PDFium proves per-instance thread-safe (upstream is not thread-safe globally, so the lock may simply be correct), or a second BEAM node |
| **R-02** | pdf.js 6.x is ESM-only and asset-path-sensitive | Medium | T-040 dedicated task; verify CJK + JPEG2000 fixtures render |
| **R-03** | **Native OOXML conversion fidelity disappoints** — an in-house reader/writer cannot match a full office suite on complex layouts | High | State expectations in-product (§9.2); aim for "layout recognisably intact" on business documents (Gate 4); the reader's layout model is versioned so fidelity improves without re-architecting; worst case a document converts as rendered images with a text layer — never as garbage |
| **R-04** | **In-house crypto is wrong** (PAdES / AESV3 written in Elixir) | High | RFC test vectors in unit tests; Gate 8 interoperability bar against Acrobat in both directions; regression suite (T-138); never silently re-sign (`max_attempts: 1`); validation failures surface, never swallow |
| **R-05** | PDF text editing fidelity disappoints users | High | Two explicit modes; refuse clearly rather than corrupting; set expectations in-product |
| **R-06** | Redaction fails to actually remove content | **Critical** | Mandatory post-hoc verification (T-134); rasterise-and-replace fallback when object removal can't prove completeness; fail the job rather than ship a leak |
| **R-07** | A NIF segfault takes down the whole BEAM | High | Corpus crash-fuzz (T-020, T-197); bounded inputs (§7.2); pinned versions; optional second BEAM node for `:ocr` (§3.3) |
| **R-08** | Undo/redo across the hybrid boundary is subtly wrong | High | Property test in T-024; coalescing rules; revision-restore as the server inverse |
| **R-09** | Coordinate bugs on rotated/cropped pages | High | §14.3 single-source geometry module + round-trip property test |
| **R-10** | Chromium absent or changed → URL/Office→PDF breaks | Medium | Explicit configured path (§3.6.6); clean feature degradation (§7.2); version captured in About |
| **R-11** | webkit2gtk on Linux breaks the UI in the desktop build | Medium | T-184 explicit test; Electron is the documented escape hatch |
| **R-12** | Scope. This is 11 tabs and ~180 controls | **High** | Phase gates; ship Phases 0–4 as a usable product before continuing |
| **R-13** | Trademark/trade-dress exposure | Medium | §2 — original name, logo and icons from day one |
| **R-14** | A `brew upgrade` silently moves a native library | Medium | `brew bundle --no-upgrade`; doctor version assertions in every `check`; `Engine.versions/0` in Settings → About |
| **R-15** | Benchmarks taken on battery or under thermal throttling are unreproducible | Medium | §14.1 — plugged in, recorded conditions; T-189 re-establishes the baseline on the actual machine |
| **R-16** | The OOXML reader's scope creeps (every edge case of Word is a bug report) | Medium | The layout model is deliberately lossy-but-honest: unsupported constructs fall back to rendered representation with a note in the conversion report, never to silent omission |

### Appendix D — Version reference (verified 2026-07-29)

Re-verify before you pin: several of these move weekly. `mix hex.outdated`
and `brew outdated` are the two commands that tell you the truth about your
own machine; this table is only what was current when the plan was written.

| Component | Version | License |
|---|---|---|
| mise | 2026.7.x | MIT |
| PostgreSQL | 18.4 — `brew install postgresql@18` | PostgreSQL licence |
| Elixir | 1.20.2 | Apache-2.0 |
| Erlang/OTP | 28.x (27 acceptable) | Apache-2.0 |
| Phoenix | 1.8.9 | MIT |
| Phoenix LiveView | 1.2.7 | MIT |
| pdfjs-dist | 6.1.200 | Apache-2.0 |
| @cantoo/pdf-lib | 2.7.4 | MIT |
| PDFium | **144.0.7543.0** — whatever `ex_pdfium 0.5.1` bundles. **Nothing may rely on a post-144 API** | BSD-3 + Apache-2.0 |
| pdfium-render | **0.8.37** (exact — `ex_pdfium` pins `=0.8.37`) | MIT / Apache-2.0 |
| ex_pdfium | 0.5.1 | MIT |
| lopdf | 0.44.0 — the `Quire.Pdf` NIF (§3.3) | MIT |
| image_ocr | 0.2.0 | Apache-2.0 (binding); Tesseract itself Apache-2.0 |
| Tesseract | 5.5.3 (Homebrew) | Apache-2.0 |
| Leptonica | 1.87.0 (Homebrew) | BSD-2-Clause |
| vix / image | **0.40.0 (exact) / 0.72.0** | MIT (**bindings only**) |
| **libvips**, as bundled in the vix artefact (`libvips-cpp.8.18.3.dylib`, from `akash-akya/sharp-libvips` `v8.18.3-rc1`) | 8.18.3 | **LGPL-3.0-or-later** — a statically Combined Work, **not** "LGPL-2.1 dynamically linked". Component inventory and evidence in §3.5; obligation discharged at §12.1 step 9 |
| Rustler | 0.38.0 | MIT / Apache-2.0 |
| rustler_precompiled | 0.8.4 | Apache-2.0 |
| chromic_pdf | 1.17.1 | Apache-2.0 |
| Saxy | 1.6.1 | MIT |
| elixlsx | 0.6.0 | MIT |
| Oban | **2.23.x** | Apache-2.0 / commercial (Oban Web/Pro not used) |
| Tauri | 2.11.5 — Phase 13 only | MIT / Apache-2.0 |
| ElixirKit | 0.1.0 — Phase 13 only | Apache-2.0 |

**Transitive Hex dependencies the earlier table omitted.** T-005's scanner
reads all of these, so they are recorded here rather than discovered by a red
pre-push hook:

| Component | License as declared on Hex |
|---|---|
| yaml_elixir | MIT |
| yamerl | **`BSD 2-Clause`** — declared with spaces, **not** the SPDX `BSD-2-Clause`. See T-005's normalisation rule |
| bunt | MIT |
| erlex | Apache-2.0 |
| deep_merge | MIT |
| statistex | MIT |
| comeonin | BSD-3-Clause |
| color | Apache-2.0 |
| sweet_xml | MIT |

**Appendix E's GPL/AGPL gate PASSES**, verified across all 71 Hex
dependencies: every one resolves to Apache-2.0, MIT, BSD or ISC. §3.5's
copyleft entries are about *obligations being larger than recorded*, not
about a banned licence being present.

### Appendix E — Definition of done (every task)

- [ ] Tests written and passing (unit + at least one integration or LiveView test)
- [ ] Runs against the fixture corpus where documents are involved
- [ ] Keyboard accessible; `aria-label` on every icon-only control
- [ ] Light and dark variants
- [ ] Loading, empty and error states implemented
- [ ] No `File.`/`Path.`/`System.cmd` outside Storage/Engine
- [ ] No new GPL/AGPL dependency; no external process besides PostgreSQL and Chromium
- [ ] No new NIF call without a dirty-scheduler declaration
- [ ] Credo + Dialyzer clean
- [ ] Telemetry emitted for anything that can be slow
- [ ] User-facing errors are plain language, not engine output
- [ ] Any new system dependency is in the `Brewfile` or `mise.toml`, has an ADR per §3.4, and is in `mise run doctor`'s assertion table — never assumed to be present
- [ ] `mise run check` green before push (the pre-push hook enforces it; do not `--no-verify` past it)
- [ ] No `CREATE EXTENSION` in any migration
- [ ] No secret in a committed file — machine-specific values live in the gitignored `.mise.local.toml`
