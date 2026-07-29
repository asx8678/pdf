//! `Quire.Pdf` NIF — the PDF *object model*, over the `lopdf` crate.
//!
//! Why this exists (ADR 0003 D1): PDFium's public C API has no outline *write*
//! and no linearizing save, so `ex_pdfium` cannot reach them and neither can a
//! fork. `Quire.Compose`, `Quire.PdfA`, `Quire.SecurityHandler` and
//! `Quire.Pades` all need to read and write raw PDF structure; this crate owns
//! that. It is a *complement* to `ex_pdfium`, not a replacement — rendering,
//! text extraction and form appearances stay there.
//!
//! Three rules drive the shape of this file:
//!   1. `lopdf::Document` is pure Rust memory with no global state, so — unlike
//!      `ex_pdfium` — there is no process-wide library lock here. Each document
//!      carries its own `Mutex`, which serialises multi-step edits on that one
//!      document and nothing else. Two documents can be worked on in parallel.
//!   2. Parsing, serialising and diffing a PDF are CPU-heavy and unbounded in
//!      the size of the input, so every NIF is `DirtyCpu` (plan3.md §7.3,
//!      T-021). `ex_pdfium` is 45/45 compliant; this crate is 8/8.
//!   3. A NIF must not panic — a panic unwinds into the BEAM. So `unwrap` and
//!      `expect` are denied below and every failure is mapped to an atom.

// See rule 3. `lopdf` returns `Result` everywhere; we map, we do not unwrap.
#![deny(clippy::unwrap_used, clippy::expect_used)]

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, MutexGuard};

use lopdf::{
    decode_text_string, Bookmark, Dictionary, Document, Error, IncrementalDocument, Object,
    ObjectId, SaveOptions,
};
use rustler::{Atom, Binary, Env, NifMap, OwnedBinary, ResourceArc};

mod atoms {
    rustler::atoms! {
        ok,
        // open
        enoent,
        eacces,
        io_error,
        invalid_pdf,
        password_error,
        unsupported_security,
        open_failed,
        // save
        alloc_failed,
        // document structure
        no_catalog,
        page_out_of_bounds,
        outline_too_deep,
        outline_too_large,
        // resource state
        lock_poisoned,
    }
}

// Bound every outline walk. A malformed or hostile document can present a
// cyclic or absurdly deep /Outlines tree; these are the same limits
// `ex_pdfium` uses for its own outline read, so the two agree on what a
// readable outline is.
const MAX_OUTLINE_DEPTH: usize = 64;
const MAX_OUTLINE_NODES: usize = 50_000;

// ── The document resource ────────────────────────────────────────────────────

/// One open PDF. `Mutex` because several NIFs need `&mut Document` (every save
/// path in `lopdf` mutates the document — see `save`) and because an edit must
/// not interleave with a save of the same handle.
struct DocumentResource {
    inner: Mutex<Inner>,
}

struct Inner {
    doc: Document,

    /// The exact bytes the document was parsed from.
    ///
    /// Kept because an incremental update is *defined* as "the original file,
    /// byte for byte, plus an appended revision" — `IncrementalDocument` writes
    /// these out verbatim before the new objects, which is what lets an
    /// existing signature stay valid (pdf-17l). The cost is that an open
    /// document holds roughly the file size in addition to the parsed object
    /// graph; that is the price of being able to sign-preserve at all.
    origin: Vec<u8>,
}

#[rustler::resource_impl]
impl rustler::Resource for DocumentResource {}

// No `Drop` impl: `Document` is plain Rust memory with no FFI handle behind it,
// so dropping the resource on GC is enough. (`ex_pdfium` needs one because
// closing a pdfium document is an FFI call that must hold its global lock.)

fn lock(resource: &DocumentResource) -> Result<MutexGuard<'_, Inner>, Atom> {
    resource.inner.lock().map_err(|_| atoms::lock_poisoned())
}

// ── Errors ───────────────────────────────────────────────────────────────────

/// Map a `lopdf::Error` onto an atom. We map its semantics; we do not invent
/// our own. `fallback` names the operation for variants that carry no useful
/// distinction.
fn error_atom(err: &Error, fallback: Atom) -> Atom {
    match err {
        Error::IO(inner) => io_error_atom(inner),
        Error::InvalidPassword | Error::Decryption(_) => atoms::password_error(),
        Error::UnsupportedSecurityHandler(_) => atoms::unsupported_security(),
        // ParseError covers InvalidFileHeader / InvalidTrailer / InvalidXref /
        // InvalidContentStream / EndOfInput; XrefError covers the three bad
        // start-offset cases. All of them mean "this is not a PDF we can read".
        Error::Parse(_)
        | Error::Xref(_)
        | Error::Syntax(_)
        | Error::InvalidOffset(_)
        | Error::IndirectObject { .. }
        | Error::MissingXrefEntry
        | Error::ObjectIdMismatch => atoms::invalid_pdf(),
        _ => fallback,
    }
}

/// `lopdf`'s writer returns `std::io::Result`, not `lopdf::Result` — every save
/// path (`Document::save_to`, `save_with_options`, `IncrementalDocument::save_to`)
/// lands here rather than in `error_atom`.
fn io_error_atom(err: &std::io::Error) -> Atom {
    match err.kind() {
        std::io::ErrorKind::NotFound => atoms::enoent(),
        std::io::ErrorKind::PermissionDenied => atoms::eacces(),
        // `IncrementalDocument` reports "still encrypted" as Unsupported.
        std::io::ErrorKind::Unsupported => atoms::unsupported_security(),
        _ => atoms::io_error(),
    }
}

fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Result<Binary<'a>, Atom> {
    let mut binary = OwnedBinary::new(bytes.len()).ok_or_else(atoms::alloc_failed)?;
    binary.as_mut_slice().copy_from_slice(bytes);
    Ok(binary.release(env))
}

// ── Opening ──────────────────────────────────────────────────────────────────

/// Parse a PDF held in memory.
#[rustler::nif(schedule = "DirtyCpu")]
fn open(bytes: Binary) -> Result<ResourceArc<DocumentResource>, Atom> {
    build(bytes.as_slice().to_vec())
}

/// Parse a PDF from disk.
///
/// This reads the file itself rather than calling `Document::load`, because we
/// need the original bytes anyway (see `Inner::origin`) and `Document::load` is
/// exactly "read the file into a buffer, then parse the buffer"
/// (lopdf-0.44.0/src/reader.rs:34 and :60) — so this is one read, not two.
#[rustler::nif(schedule = "DirtyCpu")]
fn open_file(path: String) -> Result<ResourceArc<DocumentResource>, Atom> {
    let bytes = std::fs::read(&path).map_err(|err| io_error_atom(&err))?;
    build(bytes)
}

fn build(origin: Vec<u8>) -> Result<ResourceArc<DocumentResource>, Atom> {
    let doc = Document::load_mem(&origin).map_err(|err| error_atom(&err, atoms::open_failed()))?;

    Ok(ResourceArc::new(DocumentResource {
        inner: Mutex::new(Inner { doc, origin }),
    }))
}

/// Number of pages, by walking the page tree.
#[rustler::nif(schedule = "DirtyCpu")]
fn page_count(doc: ResourceArc<DocumentResource>) -> Result<usize, Atom> {
    let guard = lock(&doc)?;
    Ok(guard.doc.get_pages().len())
}

// ── Saving ───────────────────────────────────────────────────────────────────

/// Serialise the whole document.
///
/// Takes `&mut` because `lopdf`'s writer genuinely mutates: on a document whose
/// cross-reference table is a stream it appends the new xref-stream object and
/// bumps `max_id` and the trailer (lopdf-0.44.0/src/writer.rs:204-224).
#[rustler::nif(schedule = "DirtyCpu")]
fn save(env: Env<'_>, doc: ResourceArc<DocumentResource>) -> Result<Binary<'_>, Atom> {
    let mut guard = lock(&doc)?;
    let mut out = Vec::new();

    guard
        .doc
        .save_to(&mut out)
        .map_err(|err| io_error_atom(&err))?;

    to_binary(env, &out)
}

/// Serialise with object streams and/or cross-reference streams — the T-083
/// Compress rewrite, now that linearization is dropped (ADR 0003 D3).
///
/// `use_xref_streams` only has an effect when `use_object_streams` is also
/// true: `save_with_options` short-circuits to the plain writer whenever object
/// streams are off (lopdf-0.44.0/src/writer.rs:27-32), which leaves the
/// cross-reference type at whatever the document was loaded with. The Elixir
/// wrapper documents this rather than silently correcting it.
#[rustler::nif(schedule = "DirtyCpu")]
fn save_with(
    env: Env<'_>,
    doc: ResourceArc<DocumentResource>,
    use_object_streams: bool,
    use_xref_streams: bool,
) -> Result<Binary<'_>, Atom> {
    let options = SaveOptions::builder()
        .use_object_streams(use_object_streams)
        .use_xref_streams(use_xref_streams)
        .build();

    let mut guard = lock(&doc)?;
    let mut out = Vec::new();

    guard
        .doc
        .save_with_options(&mut out, options)
        .map_err(|err| io_error_atom(&err))?;

    to_binary(env, &out)
}

/// Append a new revision to the original bytes instead of rewriting the file.
///
/// This is what keeps an existing signature verifiable (pdf-17l): everything up
/// to the original `%%EOF` is reproduced byte for byte, so the ranges an
/// existing /ByteRange covers do not move.
///
/// The set of objects to append is computed by *diffing* the live document
/// against a fresh parse of the original bytes, rather than by tracking dirty
/// ids. That keeps every present and future mutator honest for free — a writer
/// cannot forget to mark something dirty — at the cost of one extra parse and
/// one `Object` comparison per object, both of which are why this is DirtyCpu.
#[rustler::nif(schedule = "DirtyCpu")]
fn incremental_save(env: Env<'_>, doc: ResourceArc<DocumentResource>) -> Result<Binary<'_>, Atom> {
    let guard = lock(&doc)?;

    let previous =
        Document::load_mem(&guard.origin).map_err(|err| error_atom(&err, atoms::open_failed()))?;

    // Collect before constructing the IncrementalDocument: `create_from` takes
    // `previous` by value, and `get_prev_documents()` borrows the whole
    // IncrementalDocument, which would conflict with mutating `new_document`.
    let mut changed: Vec<(ObjectId, Object)> = Vec::new();
    for (id, object) in &guard.doc.objects {
        if previous.objects.get(id) != Some(object) {
            changed.push((*id, object.clone()));
        }
    }

    let max_id = guard.doc.max_id.max(previous.max_id);
    let version = guard.doc.version.clone();

    let mut incremental = IncrementalDocument::create_from(guard.origin.clone(), previous);
    for (id, object) in changed {
        incremental.new_document.set_object(id, object);
    }
    // `Document::new_from_prev` hardcodes version 1.4 and copies only the
    // previous `max_id`; both would be wrong for the appended revision.
    incremental.new_document.max_id = max_id;
    incremental.new_document.version = version;

    let mut out = Vec::new();
    incremental
        .save_to(&mut out)
        .map_err(|err| io_error_atom(&err))?;

    to_binary(env, &out)
}

// ── Outline ──────────────────────────────────────────────────────────────────

/// One outline (bookmark) node. Same shape in both directions, so a read feeds
/// straight back into a write. `page` is a 0-based page index.
#[derive(NifMap)]
struct OutlineEntry {
    title: String,
    page: Option<u32>,
    children: Vec<OutlineEntry>,
}

/// The document outline as a nested tree. `[]` when the document has none.
#[rustler::nif(schedule = "DirtyCpu")]
fn outline(doc: ResourceArc<DocumentResource>) -> Result<Vec<OutlineEntry>, Atom> {
    let guard = lock(&doc)?;
    read_outline(&guard.doc)
}

/// Replace the document outline. This is the write PDFium cannot do.
#[rustler::nif(schedule = "DirtyCpu")]
fn set_outline(
    doc: ResourceArc<DocumentResource>,
    entries: Vec<OutlineEntry>,
) -> Result<Atom, Atom> {
    let mut guard = lock(&doc)?;
    write_outline(&mut guard.doc, &entries)?;
    Ok(atoms::ok())
}

fn read_outline(doc: &Document) -> Result<Vec<OutlineEntry>, Atom> {
    let catalog = doc.catalog().map_err(|_| atoms::no_catalog())?;

    // No /Outlines at all is not an error; it is an empty outline.
    let Some(root) = catalog
        .get(b"Outlines")
        .ok()
        .and_then(|object| dereference(doc, object))
        .and_then(|object| object.as_dict().ok())
    else {
        return Ok(Vec::new());
    };

    let pages = page_indices(doc);
    let mut budget = MAX_OUTLINE_NODES;
    let mut seen = HashSet::new();

    Ok(read_siblings(
        doc,
        reference_id(root, b"First"),
        &pages,
        0,
        &mut budget,
        &mut seen,
    ))
}

fn read_siblings(
    doc: &Document,
    first: Option<ObjectId>,
    pages: &HashMap<ObjectId, u32>,
    depth: usize,
    budget: &mut usize,
    seen: &mut HashSet<ObjectId>,
) -> Vec<OutlineEntry> {
    let mut entries = Vec::new();
    let mut current = first;

    // `seen` also terminates a /Next chain that loops back on itself.
    while let Some(id) = current {
        if *budget == 0 || !seen.insert(id) {
            break;
        }
        *budget -= 1;

        let Ok(node) = doc.get_dictionary(id) else {
            break;
        };

        let children = if depth < MAX_OUTLINE_DEPTH {
            read_siblings(
                doc,
                reference_id(node, b"First"),
                pages,
                depth + 1,
                budget,
                seen,
            )
        } else {
            Vec::new()
        };

        entries.push(OutlineEntry {
            title: entry_title(doc, node),
            page: entry_page(doc, node, pages),
            children,
        });

        current = reference_id(node, b"Next");
    }

    entries
}

fn write_outline(doc: &mut Document, entries: &[OutlineEntry]) -> Result<(), Atom> {
    // Ordered by page number, so index 0 is the first page.
    let pages: Vec<ObjectId> = doc.get_pages().into_values().collect();

    // Validate before mutating anything, so a rejected outline leaves the
    // document exactly as it was.
    let mut budget = MAX_OUTLINE_NODES;
    check_entries(entries, pages.len(), 0, &mut budget)?;

    for id in stale_outline_ids(doc) {
        doc.objects.remove(&id);
    }

    // `add_bookmark` appends; without this a second call would stack a new
    // outline on top of the previous one.
    doc.bookmarks.clear();
    doc.bookmark_table.clear();
    doc.max_bookmark_id = 0;

    add_entries(doc, entries, None, &pages);

    // Resolve the `(0, 0)` placeholders left by entries with no page of their
    // own to their first descendant that has one. Must run before
    // `build_outline`, which reads `Bookmark::page`.
    doc.adjust_zero_pages();

    // `build_outline` inserts the outline objects and hands back the root id,
    // but does NOT link it into the catalog — that is the caller's job
    // (lopdf-0.44.0/README.md:388). It returns None only when there are no
    // bookmarks, which is how `set_outline(handle, [])` clears the outline.
    match doc.build_outline() {
        Some(root) => {
            doc.catalog_mut()
                .map_err(|_| atoms::no_catalog())?
                .set("Outlines", Object::Reference(root));
        }
        None => {
            doc.catalog_mut()
                .map_err(|_| atoms::no_catalog())?
                .remove(b"Outlines");
        }
    }

    Ok(())
}

fn check_entries(
    entries: &[OutlineEntry],
    page_count: usize,
    depth: usize,
    budget: &mut usize,
) -> Result<(), Atom> {
    if depth >= MAX_OUTLINE_DEPTH {
        return Err(atoms::outline_too_deep());
    }

    for entry in entries {
        if *budget == 0 {
            return Err(atoms::outline_too_large());
        }
        *budget -= 1;

        if let Some(index) = entry.page {
            if index as usize >= page_count {
                return Err(atoms::page_out_of_bounds());
            }
        }

        check_entries(&entry.children, page_count, depth + 1, budget)?;
    }

    Ok(())
}

/// Infallible: `check_entries` has already proved every page index resolves and
/// that the tree is within both bounds.
fn add_entries(
    doc: &mut Document,
    entries: &[OutlineEntry],
    parent: Option<u32>,
    pages: &[ObjectId],
) {
    for entry in entries {
        // `(0, 0)` is lopdf's "no page yet" sentinel; `adjust_zero_pages`
        // resolves it afterwards.
        let page = entry
            .page
            .and_then(|index| pages.get(index as usize).copied())
            .unwrap_or((0, 0));

        // Colour black and format 0 (plain). lopdf models per-bookmark colour
        // and italic/bold, which nothing in Quire sets yet; when T-047 needs
        // them they become optional keys on the map, not a new NIF.
        let id = doc.add_bookmark(
            Bookmark::new(entry.title.clone(), [0.0; 3], 0, page),
            parent,
        );

        add_entries(doc, &entry.children, Some(id), pages);
    }
}

/// Object ids owned by the outline currently linked into the catalog, so a
/// replacement does not leave the old tree behind as dead weight in the file.
fn stale_outline_ids(doc: &Document) -> Vec<ObjectId> {
    let Some(root_id) = doc
        .catalog()
        .ok()
        .and_then(|catalog| reference_id(catalog, b"Outlines"))
    else {
        return Vec::new();
    };

    // Refuse to delete anything if /Outlines does not point at an outline —
    // better a few orphaned objects than a shredded document.
    match doc.get_dictionary(root_id) {
        Ok(root) if !root.has(b"Type") || root.has_type(b"Outlines") => {}
        _ => return Vec::new(),
    }

    let mut ids = Vec::new();
    let mut seen = HashSet::new();
    let mut stack = vec![root_id];
    let mut budget = MAX_OUTLINE_NODES;

    while let Some(id) = stack.pop() {
        if budget == 0 {
            break;
        }
        if !seen.insert(id) {
            continue;
        }
        budget -= 1;

        let Ok(node) = doc.get_dictionary(id) else {
            continue;
        };

        // The /A action object of an item exists only to carry its
        // destination, so it dies with the item.
        if let Some(action) = reference_id(node, b"A") {
            ids.push(action);
        }
        if let Some(first) = reference_id(node, b"First") {
            stack.push(first);
        }
        if let Some(next) = reference_id(node, b"Next") {
            stack.push(next);
        }

        ids.push(id);
    }

    ids
}

// ── Object helpers ───────────────────────────────────────────────────────────

fn dereference<'a>(doc: &'a Document, object: &'a Object) -> Option<&'a Object> {
    doc.dereference(object).ok().map(|(_, resolved)| resolved)
}

fn reference_id(dict: &Dictionary, key: &[u8]) -> Option<ObjectId> {
    dict.get(key).ok()?.as_reference().ok()
}

/// Page object id -> 0-based index. `get_pages` keys are 1-based page numbers.
fn page_indices(doc: &Document) -> HashMap<ObjectId, u32> {
    doc.get_pages()
        .into_iter()
        .map(|(number, id)| (id, number.saturating_sub(1)))
        .collect()
}

fn entry_title(doc: &Document, node: &Dictionary) -> String {
    node.get(b"Title")
        .ok()
        .and_then(|title| dereference(doc, title))
        .and_then(|title| decode_text_string(title).ok())
        .unwrap_or_default()
}

fn entry_page(doc: &Document, node: &Dictionary, pages: &HashMap<ObjectId, u32>) -> Option<u32> {
    // An item points at its destination either directly (/Dest) or through a
    // GoTo action (/A -> /D).
    let destination = match node.get(b"Dest") {
        Ok(dest) => dest,
        Err(_) => {
            let action = dereference(doc, node.get(b"A").ok()?)?.as_dict().ok()?;
            action.get(b"D").ok()?
        }
    };

    // A named destination (a string or a name) would need the catalog's
    // /Names /Dests name tree to resolve; those come back as `page: nil`.
    let items = dereference(doc, destination)?.as_array().ok()?;

    match items.first()? {
        Object::Reference(id) => pages.get(id).copied(),
        // A remote/embedded go-to numbers its page directly.
        Object::Integer(number) => u32::try_from(*number).ok(),
        _ => None,
    }
}

rustler::init!("Elixir.Quire.Pdf.Native");
