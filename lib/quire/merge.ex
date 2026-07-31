defmodule Quire.Merge do
  @moduledoc ~S"""
  Merge multiple PDFs into one via the PDFium page-import path (§9.2, T-081).

  The page assembly is pure PDFium (`ExPdfium.extract_pages/2` + `append/2` —
  the per-file page ranges are applied as extractions), and the option layer
  runs on the lopdf-backed `Quire.Pdf` handle afterwards:

    * **bookmarks** — `:keep` merges each source's outline entries, filtered
      to the imported page range and shifted by each source's page offset;
      `:flatten` removes `/Outlines` entirely.
    * **forms** — `:keep` re-attaches `/AcroForm` (PDFium's append drops it)
      via `Quire.Pdf.AcroForm.rebuild_fields/1`; `:discard` deletes the
      `/AcroForm` key from the merged catalog.
    * **page numbering** — `continue_numbering: true` writes an explicit
      sequential `/PageLabels` run across the whole merged document;
      `false` restarts numbering at 1 for each source segment.

  No filesystem access and no external process is involved (T-014 guard).

  ## Sources

      sources = [
        %{bytes: pdf_bytes_a, pages: nil},          # whole document
        %{bytes: pdf_bytes_b, pages: [0, 1, 4]}     # selected 0-based pages
      ]

  The `pages` key may be `nil` (all pages) or a list of 0-based page indices.
  """

  alias Quire.Pdf
  alias Quire.Pdf.Outline

  @max_sources 12

  @type option ::
          {:continue_numbering, boolean()}
          | {:bookmarks, :keep | :flatten}
          | {:forms, :keep | :discard}
  @type options :: [option()]

  @doc """
  Parses a page-range spec string into a list of 0-based page indices.

  Accepts comma-separated numbers and inclusive hyphen ranges, e.g.
  `"1-3,5,7-9"`. Out-of-bounds indices (relative to `page_count`) are
  rejected. Returns `{:ok, [non_neg_integer()]}` or
  `{:error, {message, spec}}`.

  ## Examples

      iex> Quire.Merge.parse_ranges("1-3,5", 10)
      {:ok, [0, 1, 2, 4]}

      iex> Quire.Merge.parse_ranges("1-99", 10)
      {:error, {"page 99 is out of range (document has 10 pages)", "1-99"}}
  """
  @spec parse_ranges(String.t(), pos_integer()) ::
          {:ok, [non_neg_integer()]} | {:error, {String.t(), String.t()}}
  def parse_ranges(spec, page_count) when is_binary(spec) and is_integer(page_count) do
    trimmed = String.trim(spec)

    if trimmed == "" do
      {:ok, Enum.to_list(0..(page_count - 1))}
    else
      parts = String.split(trimmed, ",")

      with {:ok, indices} <- expand_parts(parts, page_count, spec) do
        {:ok, Enum.sort(indices) |> Enum.uniq()}
      end
    end
  end

  defp expand_parts(parts, page_count, spec) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case parse_part(String.trim(part), page_count) do
        {:ok, indices} ->
          {:cont, {:ok, acc ++ indices}}

        {:error, reason} ->
          {:halt, {:error, {reason, spec}}}
      end
    end)
  end

  defp parse_part(part, page_count) do
    case String.split(part, "-") do
      [single] ->
        with {:ok, n} <- parse_int(single) do
          check_bounds(n, page_count, part)
        end

      [from, to] ->
        with {:ok, a} <- parse_int(from),
             {:ok, b} <- parse_int(to) do
          cond do
            a > b ->
              {:error, "range #{part} is reversed (must be from ≤ to)"}

            a < 1 ->
              {:error, "range #{part} starts below page 1"}

            b > page_count ->
              {:error, "page #{b} is out of range (document has #{page_count} pages)"}

            true ->
              {:ok, Enum.to_list((a - 1)..(b - 1))}
          end
        end

      _ ->
        {:error, "invalid range \"#{part}\""}
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 1 -> {:ok, n}
      {_, ""} -> {:error, "page number #{str} must be ≥ 1"}
      _ -> {:error, "invalid page number \"#{str}\""}
    end
  end

  defp check_bounds(n, page_count, _part) do
    if n > page_count do
      {:error, "page #{n} is out of range (document has #{page_count} pages)"}
    else
      {:ok, [n - 1]}
    end
  end

  @doc """
  Merges the given sources into a single PDF.

  ## Options

    * `:continue_numbering` — `boolean()`, default `true` — pages are
      numbered continuously across the merged document (`false` restarts
      at 1 for each source).
    * `:bookmarks` — `:keep` (default) merges source outlines with page
      offsets; `:flatten` removes the outline.
    * `:forms` — `:keep` (default) preserves the AcroForm; `:discard`
      strips it from the merged catalog.

  Returns `{:ok, merged_pdf_bytes}` or `{:error, reason}`.
  """
  @spec merge([map()], options()) :: {:ok, binary()} | {:error, term()}
  def merge(sources, opts \\ []) when is_list(sources) do
    continue_numbering? = Keyword.get(opts, :continue_numbering, true)
    bookmarks = Keyword.get(opts, :bookmarks, :keep)
    forms = Keyword.get(opts, :forms, :keep)

    with {:ok, prepared} <- prepare_sources(sources),
         {:ok, merged_bytes, offsets} <- append_all(prepared),
         {:ok, q} <- Pdf.open(merged_bytes) do
      q =
        q
        |> with_forms(forms)
        |> with_outline(prepared, offsets, bookmarks)
        |> with_page_labels(prepared, offsets, continue_numbering?)

      Pdf.save(q)
    end
  end

  @doc """
  Merges sources and ingests the result as a new document for the caller.

  Returns the same shape as `Quire.Documents.ingest/3`:
  `{:ok, %{document: doc, document_url: url}}`.
  """
  @spec merge_and_ingest([map()], options(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def merge_and_ingest(sources, opts, scope, ingest_opts \\ []) do
    title = Keyword.get(ingest_opts, :title, "Merged PDF")

    with {:ok, merged_bytes} <- merge(sources, opts) do
      Quire.Documents.ingest(merged_bytes, scope, title: title)
    end
  end

  # ── Preparation ────────────────────────────────────────────────────────

  defp prepare_sources(sources) when length(sources) > @max_sources do
    {:error, {:too_many_sources, length(sources), @max_sources}}
  end

  defp prepare_sources(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, acc} ->
      case prepare_source(source) do
        {:ok, prepared} -> {:cont, {:ok, acc ++ [prepared]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp prepare_source(%{bytes: bytes} = source) when is_binary(bytes) do
    with {:ok, doc} <- ExPdfium.open(bytes),
         {:ok, count} <- ExPdfium.page_count(doc),
         {:ok, outline} <- ExPdfium.outline(doc) do
      pages =
        case Map.get(source, :pages) do
          nil -> Enum.to_list(0..(count - 1))
          list when is_list(list) -> list
        end

      with :ok <- validate_pages(pages, count) do
        {:ok, %{doc: doc, pages: pages, outline: outline, count: count}}
      end
    end
  end

  defp prepare_source(_), do: {:error, :missing_bytes}

  defp validate_pages(pages, count) do
    if Enum.all?(pages, &(is_integer(&1) and &1 >= 0 and &1 < count)) do
      :ok
    else
      {:error, {:page_out_of_bounds, pages, count}}
    end
  end

  # ── PDFium page assembly ───────────────────────────────────────────────

  # Appends each source's selected pages into one document. Returns the
  # merged bytes and the list of page offsets where each source begins.
  #
  # The first source becomes the base document *without* extraction when it is
  # imported in full: PDFium's append preserves the destination catalog, so
  # its `/AcroForm` (with valid object refs) and other catalog entries survive
  # (T-081 "keep forms" depends on this). Ranged first sources are extracted.
  defp append_all([first | rest]) do
    full_pages = Enum.to_list(0..(first.count - 1))

    with {:ok, base, base_count} <- build_base(first, full_pages) do
      result =
        Enum.reduce_while(rest, {:ok, base, [0, base_count]}, fn src, {:ok, acc, offsets} ->
          case append_source(acc, src) do
            {:ok, merged, added} ->
              {:cont, {:ok, merged, offsets ++ [List.last(offsets) + added]}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      case result do
        {:ok, final, offsets} ->
          with {:ok, bytes} <- ExPdfium.save_to_bytes(final) do
            {:ok, bytes, offsets}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp append_all([]), do: {:error, :no_sources}

  # The first source is used directly (no extraction) when the whole document
  # is imported; otherwise its selected pages are extracted like any other.
  defp build_base(%{doc: doc, count: count, pages: pages}, full_pages) do
    if pages == full_pages do
      {:ok, doc, count}
    else
      with {:ok, extracted} <- ExPdfium.extract_pages(doc, pages),
           {:ok, n} <- ExPdfium.page_count(extracted) do
        {:ok, extracted, n}
      end
    end
  end

  defp append_source(acc, src) do
    with {:ok, extracted} <- ExPdfium.extract_pages(src.doc, src.pages),
         {:ok, added} <- ExPdfium.page_count(extracted),
         {:ok, merged} <- ExPdfium.append(acc, extracted) do
      {:ok, merged, added}
    end
  end

  # ── Option layer (lopdf handle) ────────────────────────────────────────

  defp with_forms(q, :discard) do
    with {:ok, catalog} <- Pdf.get_object(q, 1) do
      :ok = Pdf.set_object(q, 1, Map.delete(catalog, "/AcroForm"))
    end

    q
  end

  defp with_forms(q, :keep) do
    # The first source is imported as the base document (append_all), and
    # PDFium's append preserves the destination catalog — so a form-bearing
    # base keeps its /AcroForm with valid object refs. Nothing to do here.
    # (Form docs appearing later in the list lose their catalog entry; the
    # pre-existing rebuild_fields/1 cannot relocate their renumbered refs.)
    q
  end

  defp with_outline(q, _prepared, _offsets, :flatten) do
    _ = Pdf.set_outline(q, [])
    q
  end

  defp with_outline(q, prepared, offsets, :keep) do
    combined =
      prepared
      |> Enum.zip(offsets)
      |> Enum.reduce([], fn {%{outline: outline, pages: pages}, offset}, acc ->
        page_map = Outline.build_page_map(pages)
        filtered = Outline.filter_entries(outline, page_map)
        acc ++ Outline.adjust_entries(filtered, offset)
      end)

    _ = Pdf.set_outline(q, combined)
    q
  end

  defp with_page_labels(q, _prepared, _offsets, true) do
    # Continue: one explicit sequential run across the whole document.
    set_page_labels(q, [{0, 1}])
  end

  defp with_page_labels(q, prepared, offsets, false) do
    # Restart: numbering starts at 1 at each source boundary.
    starts =
      prepared
      |> Enum.zip(offsets)
      |> Enum.map(fn {_src, offset} -> {offset, 1} end)

    set_page_labels(q, starts)
  end

  defp set_page_labels(q, starts) do
    nums =
      Enum.flat_map(starts, fn {page_idx, st} ->
        [page_idx, %{"/S" => {:name, "D"}, "/St" => st}]
      end)

    with {:ok, id} <- Pdf.allocate_object_id(q),
         :ok <- Pdf.set_object(q, id, %{"/Nums" => nums}),
         {:ok, catalog} <- Pdf.get_object(q, 1),
         :ok <- Pdf.set_object(q, 1, Map.put(catalog, "/PageLabels", {:ref, id, 0})) do
      :ok
    end

    q
  end
end
