# ADR 0007 — Degraded-Mode & Render.Client role

- **Status:** Accepted
- **Date:** 2026-07-29
- **Tasks:** pdf-ivb
- **Spec:** plan3.md §7.3, §8.6, §10.3

## Context

plan3.md contains a contradiction about whether PDFium is required for
document open:

- **§7.3** describes `Render.Client` as a fallback that "keeps *reading* fully
  functional even with the NIF gone", implying the document can be opened and
  viewed in degraded mode without PDFium.
- **§10.3** requires PDFium for steps 2–3 of the document open pipeline:
  encryption detection, `Render.page_count`, and `Render.page_geometry`.
  Without those, no document can be opened.

`Render.Client` was originally specified as a standalone `@behaviour Quire.Render`
implementer — a pure fallback for server-side operations. In practice,
`Render.Client` cannot produce any result without a connected browser socket:

- `page_count`, `page_geometry`, `encryption detection` all need PDFium
  because they run server-side before any LiveView hook exists to contribute
  data.
- `extract_text`, `search`, `form_fields`, `annotations`, `outline` have no
  client-side substitute available through the LiveView channel — they need
  the NIF or a full pdf.js document load + event round-trip, which the open
  pipeline cannot wait for.
- The only operation with a plausible client fallback is thumbnail
  contribution: once a document is open and the viewer hook is rendering
  pages, the hook can capture downscaled canvas PNGs and push them to the
  server.

### Considered alternatives

1. **Make `Render.Client` a full behaviour implementer** — requires every
   callback to somehow produce results from the browser. Encryption detection
   cannot be deferred to the client (passwords never leave the server). Page
   count and geometry cannot be obtained without loading the document in
   pdf.js, which requires bytes already in the browser — but open pipeline
   steps 1–4 happen server-side before the viewer mounts. Rejected as
   infeasible.

2. **Drop `@behaviour Quire.Render` from `Render.Client`** — would make the
   compiler enforcement disappear and require manual dispatch handling for
   the single real use case (thumbnail contribution). Rejected because
   keeping the behaviour contract makes the code more auditable; returning
   `{:error, :unavailable}` for inapplicable callbacks is explicit and
   honest.

3. **Move `Render.Client` to a separate thumbnail-only module** — introduces
   a new module with no compiler-guaranteed contract. Rejected in favour of
   keeping the existing structure: `Render.Client` fulfils the behaviour and
   the one real operation (thumbnails via browser capture) can be added as a
   LiveView event handler in a later phase without changing the module's
   degraded-mode contract.

## Decision

**`Render.Client` keeps `@behaviour Quire.Render` but returns
`{:error, :unavailable}` for every callback.** It is the honest statement of
what the server can do without PDFium: nothing that requires parsing the
document.

- PDFium is **mandatory** for document open. Without it, `page_count`,
  `page_geometry` and encryption detection are unavailable and the open
  pipeline fails with a clear error naming the remedy.
- The real "browser fallback" for thumbnails is a LiveView event handler that
  receives canvas captures from the pdf.js viewer hook and stores them via
  `Storage`. That event handler is separate from `Render.Client` — it
  operates on an already-open document, not as a pipeline step.
- `Render.Client.check/0` returns `{:error, "not available without browser"}`
  to distinguish "PDFium NIF is missing" from "PDFium NIF is loaded but no
  client is connected".
- plan3.md §7.3, §8.6 and §10.3 are amended to resolve the contradiction
  (this ADR's own tasks).

## Consequences

### Positive

1. **Honest accounting.** Every `Render.Client` callback returns
   `{:error, :unavailable}` — no claim of degraded functionality that cannot
   be delivered. A LiveView page that tries to call `Render.page_count/1`
   before the document is open gets an error it must handle, rather than a
   silent wrong answer.

2. **Compiler enforcement retained.** `@behaviour Quire.Render` stays, so
   adding a new callback to the behaviour produces a compile-time reminder to
   add a `{:error, :unavailable}` stub in `Render.Client`. No silent drift.

3. **Clear upgrade path.** The browser thumbnail contribution event handler
   will be added in a later phase (T-043 or similar). `Render.Client` already
   has the right shape: its `thumbnails/2` returns `{:error, :unavailable}`
   and the LiveView handler calls `Storage.put/2` directly. When the handler
   lands, `Render.Client`'s contract does not change — it simply was never
   the right tool for that job.

### Negative

1. **No document can be opened without PDFium.** If the NIF fails to load,
   the entire app is non-functional for PDF operations. This is a hard
   dependency — same severity as the database or the Phoenix web server.

2. **§7.3's "reading fully functional" degraded-mode claim must be withdrawn.**
   This ADR's tasks include that specification fix.

3. **Thumbnail contribution from the browser must be implemented as a
   separate LiveView event handler, not as a `Render.Client` callback,**
   which means the thumbnail path is not polymorphic over adapters — it is
   a special case. Acceptable because the special case (push canvas bytes
   from an already-open viewer) is inherently different from "serve a page
   count to the open pipeline".
