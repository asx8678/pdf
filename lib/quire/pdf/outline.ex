defmodule Quire.Pdf.Outline do
  @moduledoc """
  Outline re-attachment after page import operations.

  `ExPdfium.append/2` (merge) and `extract_pages/2` (split) drop the document's
  `/Outlines` catalog entry while its page objects and their annotations survive
  the page import. The result renders but has no bookmarks.

  Two operations repair the gap:

    * `transfer/3` — merge a source document's outline into a destination
      document, adjusting page indices by the offset where source pages were
      inserted. Used after `append/2`.
    * `filter_for_pages/2` — keep only outline entries whose page is in a given
      set and remap indices to new positions. Used after `extract_pages/2`.

  Both read and write outlines through `Quire.Pdf.outline/1` and
  `Quire.Pdf.set_outline/2`, so they automatically benefit from lopdf's
  outline-internal object management (bookmark dedup, orphan cleanup).

  For convenience, callers may use `Quire.Pdf.fixup_after_append/3` or
  `Quire.Pdf.fixup_after_extract/2` which combine the outline re-attachment
  with `AcroForm.rebuild_fields/1` in a single call.
  """

  alias Quire.Pdf

  @doc """
  Transfer the outline from the source document into the destination document.

  Each source outline entry's `page` index is shifted by `page_offset` (the
  number of pages that were in the destination *before* the append/import).
  Source entries are appended after any existing destination outline entries.

  ## Merge semantics

  1. Current dest outline is read and kept unchanged.
  2. Source outline is read, every `page` index incremented by `page_offset`.
  3. The combined outline is written back. Because the source pages "arrive"
     with the merge, a shifted source entry may point beyond the destination's
     current (pre-merge) page count; that is allowed here — the merged page it
     references exists once the source pages are appended.

  No-op when the source has no outline (empty list). Entries with `page: nil`
  (no destination of their own) are kept as-is — they inherit their descendant's
  destination, which `Pdf.set_outline/2` resolves via `adjust_zero_pages`.

  ## Example

      source_count = 3
      {:ok, dest_before} = Quire.Pdf.page_count(dest_doc)
      page_offset = dest_before - source_count

      :ok = Quire.Pdf.Outline.transfer(dest_doc, source_doc, page_offset)
  """
  @spec transfer(Pdf.t(), Pdf.t(), non_neg_integer()) :: :ok | {:error, atom()}
  def transfer(dest_doc, source_doc, page_offset)
      when is_reference(dest_doc) and is_reference(source_doc) and
             is_integer(page_offset) and page_offset >= 0 do
    with {:ok, source_entries} <- Pdf.outline(source_doc) do
      if source_entries == [] do
        :ok
      else
        {:ok, dest_entries} = Pdf.outline(dest_doc)
        adjusted = adjust_entries(source_entries, page_offset)
        Pdf.set_outline_merge(dest_doc, dest_entries ++ adjusted)
      end
    end
  end

  @doc """
  Filter the document's outline to entries whose `page` is in `kept_indices`,
  then remap pages to their position in the kept set.

  Used after `extract_pages/2` to rebuild the outline for the extracted
  document. `kept_indices` is the same list of original page indices passed
  to `extract_pages/2`.

  Entries with `page: nil` (no destination of their own) are kept only if at
  least one of their descendants survives; otherwise they are pruned.

  No-op when the document has no outline (returns `{:ok, []}` from
  `set_outline(doc, [])`, which removes `/Outlines` from the catalog as a
  side effect).
  """
  @spec filter_for_pages(Pdf.t(), [non_neg_integer()]) :: :ok | {:error, atom()}
  def filter_for_pages(doc, kept_indices)
      when is_reference(doc) and is_list(kept_indices) do
    page_map = build_page_map(kept_indices)

    with {:ok, entries} <- Pdf.outline(doc) do
      entries
      |> filter_entries(page_map)
      |> case do
        [] -> Pdf.set_outline(doc, [])
        filtered -> Pdf.set_outline(doc, filtered)
      end
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  @doc false
  def adjust_entries(entries, offset) when is_integer(offset) and offset >= 0 do
    Enum.map(entries, fn entry ->
      entry
      |> Map.update!(:page, fn
        nil -> nil
        idx when is_integer(idx) -> idx + offset
      end)
      |> Map.update!(:children, fn children ->
        adjust_entries(children, offset)
      end)
    end)
  end

  @doc false
  def build_page_map(kept_indices) do
    kept_indices
    |> Enum.with_index()
    |> Map.new(fn {old_idx, new_idx} -> {old_idx, new_idx} end)
  end

  @doc false
  def filter_entries(entries, page_map) do
    entries
    |> Enum.flat_map(fn entry ->
      children = filter_entries(Map.get(entry, :children, []), page_map)
      page = Map.get(entry, :page)

      cond do
        # Entry with an explicit page: keep only if page is in the kept set.
        is_integer(page) and Map.has_key?(page_map, page) ->
          [%{entry | page: Map.get(page_map, page), children: children}]

        # Entry with no page of its own: keep if any children survived.
        is_nil(page) and children != [] ->
          [%{entry | children: children}]

        # Entry with no page and no surviving children: prune.
        is_nil(page) and children == [] ->
          []

        # Entry whose page is not in the kept set: prune.
        true ->
          []
      end
    end)
  end
end
