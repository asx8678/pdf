Add page box setters, form value setters, print intent, and place-a-page-on-a-page

Four new NIFs (45 -> 49, all `DirtyCpu`) and one new render option. Everything
here is already exposed by the pinned `pdfium-render` 0.8.37; nothing needs a
dependency bump. Each capability was exercised end to end against real PDFs, and
the behaviour written into the docs is what I measured, not what the crate's
signatures imply.

## `set_page_box/4` — write a page's boundary boxes

`page_info/2` already reads `:media`/`:crop`/`:bleed`/`:trim`/`:art`; this is the
missing write side, over `PdfPageBoundaries::set/2`. Setting `:crop` is how you
crop a page; setting `:media` is how you resize one.

```elixir
{:ok, doc} = ExPdfium.set_page_box(doc, 0, :crop, %{left: 36, bottom: 36, right: 576, top: 756})
{:ok, %{width: 540.0, height: 720.0}} = ExPdfium.page_info(doc, 0)
```

The change is live on the open document — no save-and-reopen round trip. pdfium
re-derives the page size from the boxes on demand, so `page_info/2` and
`render_page/3` both see it on the next call, and the test asserts the resulting
bitmap is byte-identical to one from a reopened copy. That makes an interactive
crop (adjust, re-render, adjust) a sequence of calls on one handle.

A zero-area or non-finite rectangle is rejected up front (`:bad_option`) rather
than written and discovered later; pdfium's computed "Bounding"/BBox box is not
settable and is reported as `:unsupported_box`.

## `place_page/5` — draw another document's page onto this one

The Form XObject primitive, over `PdfPageObjects::copy_into_x_object_form_object/1`.
Stationery, watermarking from a PDF, and n-up imposition all reduce to it.

```elixir
{:ok, doc} = ExPdfium.place_page(doc, 0, letterhead, 0, %{left: 0, bottom: 0, right: 612, top: 792})
```

The source page's own coordinate space — its crop box, falling back to the media
box, since pdfium does not fall back for us — is mapped onto the target
rectangle, so a page whose box origin is not `(0, 0)` still lands where you
asked. Placing a document onto itself returns `:same_document`, for the same
reason `append/2` does: one non-reentrant per-document mutex cannot be locked
twice, and the XObject import needs `&mut` on the destination while the source is
borrowed.

## `set_text_field_value/4` and `set_checkbox_value/4` — fill AcroForm fields

A widget is addressed the way `delete_annotation/3` already addresses one: page
plus 0-based annotation index. To make that usable, `form_fields/1` now reports
that index as `:index` alongside `:page`, counting all annotations so it lines up
with `annotations/2`. **This changes the `form_fields/1` map** (a new key; nothing
removed or renamed).

```elixir
{:ok, fields} = ExPdfium.form_fields(doc)
%{page: page, index: index} = Enum.find(fields, &(&1.name == "full_name"))
{:ok, doc} = ExPdfium.set_text_field_value(doc, page, index, "Ada Lovelace")
```

Two pdfium behaviours make a naive binding here quietly wrong, so both are
handled explicitly.

**Writes can silently miss.** pdfium writes into the *annotation's* dictionary.
That is the field only when the widget and field are merged into one object — the
usual shape for simple forms, but not what a generator emits when one field owns
several widgets, where `/V` lives on a separate parent object. pdfium reports no
error; the value simply does not take. So every write is read back through pdfium
and a mismatch is returned as `:value_not_applied`. The new
`test/fixtures/forms_kids.pdf` (with a generator beside it, in the style of
`forms_gen.py`) pins this: it contains both shapes, and the test asserts the
non-merged field errors while the merged one in the same document succeeds.

**Appearance streams decide what is drawn.** Measured, not assumed:

| | value reads back / survives save | `render_page/3` draws it | `flatten/1` bakes it |
|---|---|---|---|
| checkbox | yes | yes | **yes** |
| text, `/NeedAppearances` or no `/AP` | yes | yes | no |
| text, stale `/AP`, no `/NeedAppearances` | yes | no | no |

A checkbox is correct everywhere, because its appearances are pre-baked per state
under `/AP /N` and pdfium switches `/AS` with the value. A text value is not:
pdfium's form layer builds an appearance for rendering but never writes it back
to `/AP`, and `FPDFPage_Flatten` bakes `/AP` while ignoring `/V`. Generating a
text appearance stream means font metrics and content-stream emission, which is
beyond a binding — and pdfium's own escape hatch for supplying one,
`FPDFAnnot_SetAP`, is unreachable from a downstream crate: it *is* on the public
`PdfiumLibraryBindings` trait, but every raw `FPDF_ANNOTATION`/`FPDF_PAGE`/
`FPDF_DOCUMENT` accessor in `pdfium-render` 0.8.37 is `pub(crate)`, so there is no
argument to call it with. The docs say this plainly rather than implying a
round-trip that works.

**Radio buttons are deliberately not exposed.**
`PdfFormRadioButtonField::set_checked()` takes the on-state name from the
widget's *current* `/AS` rather than its export value, so selecting an unselected
button writes the literal `"Off"` — and writes it to the kid widget, not the
group's parent field. Verified against `forms.pdf`: after `set_checked()` the
group's `/V` is unchanged and the selection does not move. (It also prints two
`println!` debug lines, which a NIF should never do.) Rather than ship a function
that silently does the wrong thing, this PR ships none; happy to add it the
moment the crate is fixed.

## `print_quality:` option on `render_page/3`

Sets pdfium's `FPDF_PRINTING` via `PdfRenderConfig::use_print_quality/1`, default
`false`. A document that stipulates separate screen and print quality renders at
its print quality; one that does not is unaffected. It also selects the *print*
appearance of annotations that carry one — the same appearance `flatten/1` bakes
— so it is the right flag when a bitmap is headed for paper.

## Notes for review

- Every new NIF is `#[rustler::nif(schedule = "DirtyCpu")]` and goes through the
  existing `with_pdfium` lock helper; error atoms are new members of the existing
  `atoms!` block, and validation reuses `valid_rect`/`valid_positive_f32`/
  `page_index_u16`/`validate_string`.
- `release_invariants_test.exs`'s NIF count assertions go 45 -> 49. Its
  Rust-exports-equal-Elixir-stubs check is unchanged and still passes.
- One small refactor: `annot_rect/4` is renamed `pdf_rect/4` and moved up beside
  `rect_of/1`, its inverse, because the page-box code needs it too. Four call
  sites, no behaviour change.
- New tests: 21 across five describe blocks, including a concurrency test that
  drives `place_page/5` (two per-document locks) 100 times at 32-way concurrency.
- Heads up, unrelated to this PR: `mix test` on a clean `v0.5.1` already fails
  `release_invariants_test.exs:12` — the committed
  `checksum-Elixir.ExPdfium.Native.exs` still lists `v0.4.3` artefacts. That is
  the release-ordering step described in `lib/ex_pdfium/native.ex`; it needs a
  regenerate-and-commit.
