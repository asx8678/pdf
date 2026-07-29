defmodule Quire.Pdf do
  @moduledoc """
  The PDF object model — reading and writing raw PDF structure.

  This is the foundation `Quire.Compose`, `Quire.PdfA`, `Quire.SecurityHandler`
  and `Quire.Pades` build on. It exists because PDFium's public C API has no
  outline *write* and no linearizing save (ADR 0003), so `ExPdfium` cannot
  reach them and neither could a fork of it. Rendering, text extraction, search
  and form appearances stay in `ExPdfium`; this module owns the file format.

  A handle is an opaque reference to a document parsed into memory. It is
  released by the garbage collector — there is nothing to close. Handles are
  safe to share between processes; each one serialises its own operations, and
  two different handles never block each other.

  ## Round trip

      {:ok, doc} = Quire.Pdf.open(bytes)
      :ok = Quire.Pdf.set_outline(doc, [%{title: "Chapter 1", page: 0}])
      {:ok, saved} = Quire.Pdf.save(doc)

  ## Two ways to save

  `save/1` rewrites the whole file. `incremental_save/1` reproduces the original
  bytes verbatim and appends a new revision, which is what keeps an existing
  digital signature verifiable.

  Sub-modules: `Quire.Pdf.Outline` (outline write and re-attachment after page import)
  and `Quire.Pdf.AcroForm` (/AP appearance-stream generation and field rebuild after page import).

  ## Post-import fixup

  `ExPdfium.append/2` (merge) and `ExPdfium.extract_pages/2` (split) drop the
  `/AcroForm` and `/Outlines` catalog entries from the output document while
  leaving widget annotations and page objects intact. Call the fixup functions
  after any page-import operation to re-attach both:

      # After merge (append)
      {:ok, merged} = ExPdfium.append(dest, source)
      {:ok, merged_bytes} = ExPdfium.save_to_bytes(merged)
      {:ok, merged_q} = Quire.Pdf.open(merged_bytes)
      {:ok, source_q} = Quire.Pdf.open(source_pdf_bytes)
      {:ok, dest_count} = Quire.Pdf.page_count(merged_q)
      {:ok, src_count} = Quire.Pdf.page_count(source_q)
      page_offset = dest_count - src_count
      :ok = Quire.Pdf.fixup_after_append(merged_q, source_q, page_offset)

      # After split (extract)
      {:ok, extracted} = ExPdfium.extract_pages(source, [1, 3, 5])
      {:ok, ext_bytes} = ExPdfium.save_to_bytes(extracted)
      {:ok, ext_q} = Quire.Pdf.open(ext_bytes)
      :ok = Quire.Pdf.fixup_after_extract(ext_q, [1, 3, 5])

  ## Known limits of the underlying `lopdf` 0.44.0

    * `SaveOptions` has a `linearize` flag that **nothing in the writer reads** —
      lopdf can detect linearization but not produce it. `save_with/2` therefore
      does not expose it. This is why ADR 0003 D3 re-specced Compress as object
      streams plus cross-reference streams.
    * `outline/1` reports `page: nil` for an item whose destination is a *named*
      destination, because resolving one needs the catalog's `/Names /Dests`
      name tree, which lopdf only exposes through a type it does not re-export.
    * An incremental update cannot mark an object as deleted; lopdf's
      `IncrementalDocument` only appends. Objects a mutation removed stay
      reachable through the previous cross-reference table as unreferenced
      garbage.

  """

  alias Quire.Pdf.AcroForm
  alias Quire.Pdf.Native
  alias Quire.Pdf.Outline

  @typedoc "An open document. Released by the garbage collector."
  @opaque t :: reference()

  @typedoc """
  One outline (bookmark) node.

  `page` is a 0-based page index, or `nil` for an item with no destination of
  its own — such an item inherits the destination of its first descendant that
  has one. On the way in, `:page` and `:children` may be omitted.
  """
  @type outline_entry :: %{
          required(:title) => String.t(),
          optional(:page) => non_neg_integer() | nil,
          optional(:children) => [outline_entry()]
        }

  @typedoc "An outline node as returned by `outline/1`. Every key is present."
  @type outline_node :: %{
          title: String.t(),
          page: non_neg_integer() | nil,
          children: [outline_node()]
        }

  @typedoc """
  A PDF object as decoded from the file. Tagged tuples distinguish PDF types
  that have no direct Elixir equivalent:

    * `nil` — null
    * `boolean` — boolean
    * `integer` / `float` — number
    * `binary` — literal or hex string
    * `{:name, String.t()}` — a PDF name (e.g. `{:name, "Catalog"}`)
    * `{:ref, pos_integer(), non_neg_integer()}` — indirect reference
    * `{:stream, %{String.t() => pdf_object()}, binary()}` — stream with dictionary and data
    * `[pdf_object()]` — array
    * `%{String.t() => pdf_object()}` — dictionary (keys are "/Key" strings)
  """
  @type pdf_object ::
          nil
          | boolean()
          | integer()
          | float()
          | String.t()
          | {:name, String.t()}
          | {:ref, pos_integer(), non_neg_integer()}
          | {:stream, %{String.t() => pdf_object()}, binary()}
          | [pdf_object()]
          | %{String.t() => pdf_object()}

  @typedoc "An indirect object reference: `{object_number, generation_number}`."
  @type object_id :: {pos_integer(), non_neg_integer()}

  @doc """
  The document catalog as a decoded dictionary.

  The keys are `/Name` strings, matching PDF convention. The value at
  `catalog["/Pages"]` is typically a `{:ref, num, gen}` pointing to the page
  tree root.
  """
  @spec catalog(t()) :: {:ok, pdf_object()} | {:error, atom()}
  def catalog(doc) when is_reference(doc), do: Native.catalog(doc)

  @doc """
  Fetch an indirect object by its id.

  Accepts `{obj_num, gen_num}` or a bare integer (treated as `{num, 0}`).

  ## Examples

      {:ok, obj} = Quire.Pdf.get_object(doc, {3, 0})
      {:ok, obj} = Quire.Pdf.get_object(doc, 3)
  """
  @spec get_object(t(), object_id() | pos_integer()) ::
          {:ok, pdf_object()} | {:error, atom()}
  def get_object(doc, id)

  def get_object(doc, {obj_num, gen_num})
      when is_reference(doc) and is_integer(obj_num) and is_integer(gen_num) do
    Native.get_object(doc, obj_num, gen_num)
  end

  def get_object(doc, obj_num) when is_reference(doc) and is_integer(obj_num) do
    Native.get_object(doc, obj_num, 0)
  end

  @doc """
  Replace (or insert) an indirect object.

  `id` accepts the same forms as `get_object/2`. The object is inserted
  whether or not the id already exists — this is how callers add new objects.

  ## Examples

      Quire.Pdf.set_object(doc, {42, 0}, %{"/Type" => {:name, "Outline"}})
      Quire.Pdf.set_object(doc, 42, %{"/Type" => {:name, "Outline"}})
  """
  @spec set_object(t(), object_id() | pos_integer(), pdf_object()) ::
          :ok | {:error, atom()}
  def set_object(doc, id, object)

  def set_object(doc, {obj_num, gen_num}, object)
      when is_reference(doc) and is_integer(obj_num) and is_integer(gen_num) do
    with {:ok, :ok} <- Native.set_object(doc, obj_num, gen_num, object) do
      :ok
    end
  end

  def set_object(doc, obj_num, object) when is_reference(doc) and is_integer(obj_num) do
    with {:ok, :ok} <- Native.set_object(doc, obj_num, 0, object) do
      :ok
    end
  end

  @doc """
  Allocate a fresh, unused object id and advance the document's counter.

  Callers writing new objects need an id that does not collide with an existing
  one. Each call increments the document's `max_id` and returns the new value,
  so two consecutive calls never return the same id. No concurrent writer
  touches the same document handle.
  """
  @spec allocate_object_id(t()) :: {:ok, pos_integer()} | {:error, atom()}
  def allocate_object_id(doc) when is_reference(doc), do: Native.allocate_object_id(doc)

  # Matches MAX_OUTLINE_DEPTH in native/quire_pdf/src/lib.rs. Checked here as
  # well as there because the NIF's argument decoder recurses on the Rust
  # stack before any of our code reaches it — this is the guard that actually
  # prevents a pathological term from overflowing it.
  @max_outline_depth 64

  @doc """
  Parse a PDF held in memory.

  Returns `{:error, :invalid_pdf}` for anything that is not a readable PDF, and
  `{:error, :password_error}` for one that needs a password.
  """
  @spec open(binary()) :: {:ok, t()} | {:error, atom()}
  def open(bytes) when is_binary(bytes), do: Native.open(bytes)

  @doc """
  Parse a PDF from disk.

  Prefer this to reading bytes via the Storage layer then calling `open/1`:
  it reads inside the dirty scheduler that is going to do the parsing anyway,
  and holds one copy of the bytes instead of two.
  """
  @spec open_file(Path.t()) :: {:ok, t()} | {:error, atom()}
  def open_file(path) when is_binary(path), do: Native.open_file(path)

  @doc """
  Number of pages, counted by walking the page tree.
  """
  @spec page_count(t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def page_count(doc) when is_reference(doc), do: Native.page_count(doc)

  @doc """
  Serialise the whole document to PDF bytes.

  This does not close the handle, but it is not a pure read either: on a
  document whose cross-reference table is a stream, lopdf's writer appends the
  new cross-reference stream object to the document and bumps its trailer. Two
  consecutive saves of an untouched document can therefore differ by an object
  number. Use `incremental_save/1` when byte stability of the original matters.
  """
  @spec save(t()) :: {:ok, binary()} | {:error, atom()}
  def save(doc) when is_reference(doc), do: Native.save(doc)

  @doc """
  Serialise with object streams and/or cross-reference streams.

  This is Compress (T-083). Object streams pack non-stream objects into a
  single deflated stream, which is where the size reduction comes from.

  ## Options

    * `:use_object_streams` — default `true`
    * `:use_xref_streams` — default `true`

  `:use_xref_streams` only takes effect when `:use_object_streams` is also
  true. With object streams off, lopdf short-circuits to the plain writer and
  keeps whatever cross-reference type the document was loaded with. That
  asymmetry is lopdf's, and is surfaced rather than papered over.

  Object streams require PDF 1.5, so lopdf raises the document's version to 1.5
  if it was lower. On a small document the result can be *larger* than `save/1`
  — the fixed cost of a compressed stream plus a cross-reference stream is not
  free. The win shows up once there are enough objects to pack.
  """
  @spec save_with(t(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def save_with(doc, opts \\ []) when is_reference(doc) and is_list(opts) do
    object_streams = Keyword.get(opts, :use_object_streams, true)
    xref_streams = Keyword.get(opts, :use_xref_streams, true)

    if is_boolean(object_streams) and is_boolean(xref_streams) do
      Native.save_with(doc, object_streams, xref_streams)
    else
      {:error, :bad_option}
    end
  end

  @doc """
  Serialise as an incremental update: the original bytes, then a new revision.

  Everything up to the original `%%EOF` is reproduced byte for byte, so the
  ranges an existing `/ByteRange` covers do not move and a signature over them
  stays verifiable.

  The appended revision holds exactly those objects that differ from the
  original, computed by diffing rather than by dirty-tracking, so no mutation
  can forget to declare itself.

  Returns `{:error, :unsupported_security}` for a document that is still
  encrypted — lopdf refuses to append to one it has not decrypted.
  """
  @spec incremental_save(t()) :: {:ok, binary()} | {:error, atom()}
  def incremental_save(doc) when is_reference(doc), do: Native.incremental_save(doc)

  @doc """
  The document outline (bookmarks) as a nested tree.

  `{:ok, []}` when the document has no outline. See the module docs for when
  `page` comes back `nil`.
  """
  @spec outline(t()) :: {:ok, [outline_node()]} | {:error, atom()}
  def outline(doc) when is_reference(doc), do: Native.outline(doc)

  @doc """
  Replace the document outline. This is the write PDFium cannot do.

  Any previous outline is discarded, including its objects — repeated calls do
  not accumulate dead weight in the file. Passing `[]` removes the outline
  entirely.

  Entries are validated in Elixir before the NIF is entered, and page indices
  are validated against the page tree before anything is mutated, so a rejected
  outline leaves the document untouched and no input raises. Errors:
  `:bad_outline_entry`, `:bad_outline_title`, `:page_out_of_bounds`,
  `:outline_too_deep` (more than #{@max_outline_depth - 1} levels of nesting —
  the deepest accepted node sits at depth #{@max_outline_depth - 1}),
  `:outline_too_large`, `:no_catalog`.

      :ok =
        Quire.Pdf.set_outline(doc, [
          %{title: "Part One", page: 0, children: [%{title: "Chapter 1", page: 1}]},
          %{title: "Part Two", page: 4}
        ])

  Bookmark colour and bold/italic styling are not settable yet; lopdf models
  both, and they become optional keys on an entry when something needs them.
  """
  @spec set_outline(t(), [outline_entry()]) :: :ok | {:error, atom()}
  def set_outline(doc, entries) when is_reference(doc) and is_list(entries) do
    # Validate in Elixir first. rustler's derived decoder raises ErlangError on
    # a shape it cannot decode, which would break this function's contract —
    # a negative :page is an ordinary caller slip (the classic 0-based/1-based
    # confusion), not an exceptional condition, so it gets {:error, _} like
    # every other bad input here.
    with :ok <- validate(entries, 0),
         {:ok, :ok} <- Native.set_outline(doc, normalise(entries)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate([], _depth), do: :ok

  defp validate(_entries, depth) when depth >= @max_outline_depth,
    do: {:error, :outline_too_deep}

  defp validate(entries, depth) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case validate_entry(entry, depth) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_entry(%{} = entry, depth) do
    page = Map.get(entry, :page)

    cond do
      not is_binary(Map.get(entry, :title)) ->
        {:error, :bad_outline_title}

      # Upper bound as well as lower: rustler's decoder raises on an integer
      # too large for the Rust-side type, and no real document has 2^32 pages.
      # The NIF still checks it against the actual page tree.
      not (is_nil(page) or (is_integer(page) and page >= 0 and page <= 0xFFFFFFFF)) ->
        {:error, :page_out_of_bounds}

      true ->
        validate(children(entry), depth + 1)
    end
  end

  defp validate_entry(_not_a_map, _depth), do: {:error, :bad_outline_entry}

  # Fill in the keys the NIF's decoder requires but callers may omit.
  defp normalise(entries) do
    Enum.map(entries, fn entry ->
      %{
        title: Map.fetch!(entry, :title),
        page: Map.get(entry, :page),
        children: normalise(children(entry))
      }
    end)
  end

  defp children(entry) do
    case Map.get(entry, :children, []) do
      list when is_list(list) -> list
      _ -> [:invalid]
    end
  end

  # ── Post-import fixup convenience ──────────────────────────────────────────

  @doc """
  Re-attach `/AcroForm` and `/Outlines` after a page import (merge via
  `ExPdfium.append/2`).

  `ExPdfium.append/2` (merge) drops the `/AcroForm` and `/Outlines` catalog
  entries while keeping widget annotations on imported pages. This function
  calls `Quire.Pdf.AcroForm.rebuild_fields/1` to rediscover widget annotations
  and rebuild the `/AcroForm /Fields` array, then calls
  `Quire.Pdf.Outline.transfer/3` to merge the source document's outline entries
  (shifted by `page_offset`).

  `page_offset` is the number of pages that were in the destination document
  *before* the append — each source outline entry's `:page` index is incremented
  by this amount.

  ## Example

      {:ok, merged} = ExPdfium.append(dest_ex, source_ex)
      {:ok, merged_bytes} = ExPdfium.save_to_bytes(merged)
      {:ok, merged_q} = Quire.Pdf.open(merged_bytes)
      {:ok, source_q} = Quire.Pdf.open(source_pdf_bytes)

      {:ok, dest_count} = Quire.Pdf.page_count(merged_q)
      {:ok, src_count} = Quire.Pdf.page_count(source_q)
      page_offset = dest_count - src_count

      :ok = Quire.Pdf.fixup_after_append(merged_q, source_q, page_offset)
      {:ok, final_bytes} = Quire.Pdf.save(merged_q)
  """
  @spec fixup_after_append(t(), t(), non_neg_integer()) :: :ok | {:error, atom()}
  def fixup_after_append(merged_doc, source_doc, page_offset)
      when is_reference(merged_doc) and is_reference(source_doc) and
             is_integer(page_offset) and page_offset >= 0 do
    with :ok <- AcroForm.rebuild_fields(merged_doc),
         :ok <- Outline.transfer(merged_doc, source_doc, page_offset) do
      :ok
    end
  end

  @doc """
  Re-attach `/AcroForm` and `/Outlines` after a page extraction (split via
  `ExPdfium.extract_pages/2`).

  `ExPdfium.extract_pages/2` (split) drops the `/AcroForm` and `/Outlines` catalog
  entries while keeping widget annotations on extracted pages. This function calls
  `Quire.Pdf.AcroForm.rebuild_fields/1` to rediscover widget annotations and
  rebuild the `/AcroForm /Fields` array, then calls
  `Quire.Pdf.Outline.filter_for_pages/2` to keep only outline entries whose page is
  in `kept_indices` and remap page indices.

  `kept_indices` is the same list of 0-indexed page indices passed to
  `ExPdfium.extract_pages/2`.

  ## Example

      {:ok, extracted} = ExPdfium.extract_pages(source_ex, [1, 3, 5])
      {:ok, ext_bytes} = ExPdfium.save_to_bytes(extracted)
      {:ok, ext_q} = Quire.Pdf.open(ext_bytes)
      :ok = Quire.Pdf.fixup_after_extract(ext_q, [1, 3, 5])
      {:ok, final_bytes} = Quire.Pdf.save(ext_q)
  """

  @spec fixup_after_extract(t(), [non_neg_integer()]) :: :ok | {:error, atom()}
  def fixup_after_extract(extracted_doc, kept_indices)
      when is_reference(extracted_doc) and is_list(kept_indices) do
    with :ok <- AcroForm.rebuild_fields(extracted_doc),
         :ok <- Outline.filter_for_pages(extracted_doc, kept_indices) do
      :ok
    end
  end

  @doc false
  def check do
    # Prove the Rustler NIF loads. The stub (not yet replaced) raises
    # `ErlangError` with `original: :nif_not_loaded`. If the NIF loaded
    # and is real, calling with nil fails at argument decoding (raises
    # something else) or succeeds (unexpected but treated as :ok).
    # Prove the Rustler NIF loads by trying to parse an empty byte string.
    # An empty string is invalid PDF but reaches the NIF's decoder, proving
    # the crate initialised. A stub raises at function dispatch instead.
    case Native.open(<<>>) do
      {:error, _reason} -> :ok
      {:ok, _doc} -> :ok
      other -> {:error, "unexpected return: #{inspect(other)}"}
    end
  rescue
    _e in [ErlangError] -> {:error, "NIF not loaded"}
    _ -> :ok
  end
end
