# ADR 0003 — ex_pdfium capability map, and who owns the gaps

- **Status:** accepted
- **Date:** 2026-07-29
- **Tasks:** pdf-ryz (P0). Re-scopes T-018, T-047, T-065, T-083, T-123.
- **Spec:** plan3.md §3.3, §7.3, §9

## Context

§3.3 credits PDFium with capabilities it does not have, and §3.3 itself forbids
designing around the table — so nobody would have questioned it until Phase 2 or
Phase 4. This ADR replaces that row with a map built by reading source.

**Ground truth.** `deps/ex_pdfium/lib/ex_pdfium.ex` (51 distinct public function
names across 59 `def` clauses) and `native/ex_pdfium/src/lib.rs` (45 NIFs, all
`DirtyCpu`). The wrapped crate is `pdfium-render` 0.8.37, whose tarball SHA-256
matches `Cargo.lock` and which vendors **the real PDFium public C headers** at
`include/pdfium_7543/` — the exact API surface of the PDFium 144.0.7543.0 binary
ex_pdfium bundles. Every "PDFium cannot do X" claim below is checked against
those headers, not against recollection.

**Verdict:** of the 33 verbs on the §3.3 PDFium row, **22 present, 9 partial,
2 missing**.

## The two missing verbs are not forkable

This is the finding that matters, and it is stronger than pdf-ryz assumed.

**Outline write.** `fpdf_doc.h` exposes exactly seven `FPDFBookmark_*` symbols
and all seven are getters: `Find`, `GetAction`, `GetCount`, `GetDest`,
`GetFirstChild`, `GetNextSibling`, `GetTitle`. Grepping all 22 headers returns
the same seven — there is no `Create`/`Insert`/`SetTitle`/`Delete`/`Move`
anywhere in PDFium's public API. `pdfium-render` mirrors this: `PdfDocument` has
`bookmarks()` with **no** `bookmarks_mut()`, on adjacent lines to
`attachments_mut()`, `fonts_mut()` and `pages_mut()`.

**Linearizing save.** Likewise absent. PDFium can *detect* linearization; it
cannot produce it.

So R-01's "patch the MIT fork" escape does not reach either one. This was the
crux of pdf-ryz, and it is now settled by the headers rather than by inference.

## Decisions

### D1 — A PDF object model, as a Rustler NIF over `lopdf`

Four planned modules (`Quire.Compose`, `Quire.PdfA`, `Quire.SecurityHandler`,
`Quire.Pades`) already assume the ability to read and write raw PDF structure.
Nobody owned it. The plan implies a pure-Elixir parser/writer at 1–2 weeks.

**Instead: `Quire.Pdf` is a Rustler NIF over `lopdf` 0.44.0 (MIT).** It provides,
verified against docs.rs: `Document::load` and `save`/`save_modern`;
modification of the catalog and arbitrary dictionaries; `IncrementalDocument`
for appending to original bytes; `SaveOptions::use_object_streams(true)` and
`use_xref_streams(true)`; `Bookmark`/`Outline` with `add_bookmark()` and
`build_outline()`; and `authenticate_password()` for encrypted documents.

This is a deliberate change to the plan's implied approach. It is permitted:
§3.4 bans **external processes**, not native code — a Rust library linked as a
NIF is the same shape as `ex_pdfium` and `vix`, both already in the tree.

`mise.toml` pins `rust = "1.91"`. The binding constraint is **rustler 0.38.0**,
whose manifest declares `rust-version = "1.91"` — cargo hard-refuses below it,
with no override. `lopdf` 0.44.0 needs only 1.88. (An earlier draft of this ADR
said 1.90/1.85; both figures were wrong and neither was the real constraint.
`ex_pdfium` never exposed this because it ships a precompiled NIF, so nobody
ever compiled rustler.)

It closes D2, D3 and most of D6 at once, and replaces the single largest cost
item found.

### D2 — Outline write → `Quire.Pdf.Outline`

**Not** client-side. `@cantoo/pdf-lib` 2.7.4 has **no outline or bookmark API of
any kind**, and is not even vendored (there is no `assets/package.json`; the
plan's only pointer to it cites the wrong task). Routing outline write there
would have been unbuildable — it was caught in adversarial review, not in
design.

Owner: `Quire.Pdf.Outline` over D1, using `lopdf`'s `Bookmark`/`Outline`. Owns
the five `doc.bookmark_*` operations. They stay **server-authoritative**, so
their §7.4 undo payloads are unaffected.

### D3 — Linearization: dropped

Keep the linearization *read* for the Properties dialog. Re-spec Compress as
**object streams + xref streams**, which `lopdf` supports directly and which its
own documentation measures at 11–61% size reduction — most of the win. Fast
web view matters little for a localhost-first application.

### D4 — Page boxes → upstream a PR to `ex_pdfium`

**Form field set is NOT reachable through this route.** The page-box setters
ARE: `pdfium-render` exposes `boundaries_mut().set_media/crop/bleed/trim/art`
on `PdfPage`, which is a public type reachable from a NIF.

Form-field value set and appearance-stream generation is a different story.
While `FPDFAnnot_SetAP` and `FPDFAnnot_SetStringValue` exist on the public
`PdfiumLibraryBindings` trait, every path to the `FPDF_ANNOTATION` handle
needed to call them is `pub(crate)` — `PdfDocument::handle` (document.rs:204),
`PdfPage::page_handle` (page.rs:238),
`PdfPageAnnotationPrivate::handle` (annotation/private.rs:129),
`PdfFormFieldPrivate::annotation_handle` (field.rs:405). So a NIF written
against this crate **cannot** call these trait methods.

**Appearance-stream generation stays with `Quire.Pdf.AcroForm` over `lopdf`,
exactly as D5 already assigns it.** D4 should not have offered the raw-trait
path as an alternative.

The page-box change is visible on the OPEN document — `page_info` and
`render_page` both pick it up — not only after save+reopen.

Route for the page-box PR to `jtippett/ex_pdfium`, which is active (0.4.1 →
0.5.1 in three weeks). Vendored fork as fallback. A from-source NIF build
measures **13.85 s**, so the build cost is not the objection — the objection
is that a fork must vendor `libpdfium` (5.5 MB per target) and run its own
release matrix, since a from-source build does not bundle it.

**Form XObject / place-a-page-on-a-page** belongs here too, not in Elixir:
`pdfium-render` exposes the whole API. This means **T-065 is not doubly
blocked** and T-064's "background: another PDF" needs no rasterise fallback.

### D5 — Form field values

PDFium's setter writes `/V` but never regenerates `/AP`. `flatten/1` bakes
`/AP` and **ignores `/V` entirely**. So a `/V`-only write through `flatten/1`
produces the *old or empty* appearance and silently discards what the user
typed.

**Important distinction: `render_page/3` is more forgiving.** It DOES draw a
text `/V` write when `/NeedAppearances true` is set or the widget has no `/AP`.
It does NOT do this when the widget already has a stale `/AP` — PDFium caches
the existing appearance. So a preview render after a value-only write is honest
for `/AP`-less or `/NeedAppearances`-flagged widgets, but a flatten is not.
This matters for T-018 (interactive editing: the preview layer is honest) and
T-047 (batch flattening: must pre-generate `/AP`).

**Hard rule:** any `/V` write MUST also write `/AP` before the document is
flattened or rasterised. `Quire.Pdf.AcroForm` owns appearance-stream generation
— this is font metrics plus content-stream emission, not a dictionary write,
and is estimated accordingly.

#### Additional constraint: multi-widget fields

PDFium's form-value write targets the **annotation** dictionary. It only
propagates to the field value when the widget and field are merged into a single
object. On the standard non-merged structure — one field object with separate
kid widget annotations — the write lands silently on the kid and pdfium never
reads it back, with no error. ex_pdfium **cannot fill a multi-widget field at
all** through its `PdfFormField` API.

`Quire.Pdf.AcroForm` must own this case regardless of whether the upstream PR
is accepted. Value writes to multi-widget fields must reach every kid widget's
`/V` and `/AP`, which requires direct dictionary manipulation through `lopdf`
(D1).

## Gaps not on the §3.3 row at all

Found while enumerating; recorded so §3.3's completeness claim is actually true.

| Gap | Status | Owner |
|---|---|---|
| **Crop-origin coordinate frame.** On a non-zero-origin CropBox, every spatial result (text, search, annotation, image, link bounds) is in the **MediaBox** frame while `render_page/3` rasterises the **CropBox** region. `ExPdfium.bounds_to_pixels/3` does not reconcile them. | ✗ | `Quire.Render.Pdfium` must do its own conversion, subtracting `boxes.crop` (falling back to `boxes.media` — PDFium does not fall back) and composing page `/Rotate`. Needs a `crop_nonzero_origin.pdf` fixture and a **Gate 2 exit criterion**. |
| **`/AcroForm` and `/Outlines` do not survive page import.** `append/2` and `extract_pages/2` drop them while leaving widget annotations behind — the output *looks* like a form and is not one. This makes T-081 Merge's documented "keep forms" option unimplementable through `append/2`. | ✗ | `Quire.Pdf.AcroForm` re-attaches after import. T-081's row must read "bookmark **and form** handling". |
| Six backed capabilities absent from the §3.3 row: `links/2`, `permissions/1`, `signatures/1`, `page_objects/2`, `object_display_rotation/3`, `rotate_page/3` | ✓ present | `Quire.Render.Pdfium`. Note permission *read* is in-NIF even though permission *write* is correctly assigned to `Quire.SecurityHandler`. |
| Print-intent rendering | ~ partial | `render_page/3` has no print flag; `PdfRenderConfig::use_print_quality` exists in the crate but is unbound. Fold into the D4 PR. |

## Consequences

- §3.3's PDFium row must be rewritten; `Quire.Compose`'s charter widens beyond
  "content-stream generation", and `Quire.Pdf` is added as its foundation.
- T-083 Compress loses linearization and gains object/xref streams.
- T-047 keeps bookmark editing in Phase 2, server-side, over `Quire.Pdf`.
- T-018's callback surface must account for the crop-origin conversion.
- The PDFium version is **144.0.7543.0**, not the 151.x Appendix D claims, and
  `pdfium-render` is 0.8.37, not 0.9.3.
- `ex_pdfium` serialises every call behind a process-wide mutex, so §7.2's
  parallel-render assumption is false (tracked separately).
