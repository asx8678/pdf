defmodule Quire.Split do
  @moduledoc ~S"""
  Split a PDF into multiple documents via PDFium page import (§9.2, T-082).

  Five modes:

    * `{:every_n, n}` — one output every N pages
    * `{:bookmarks, level}` — split at outline destinations (1-based level;
      level 1 = top-level bookmarks)
    * `{:ranges, groups}` — one output per explicit range group, where each
      group is a list of 0-based page indices
    * `{:file_size, target}` — greedy partition whose measured output sizes
      stay under a target byte count
    * `{:extract, pages}` — one single-page output per selected page

  Each output is produced by `ExPdfium.extract_pages/2` (PDFium page import),
  and the batch is packaged as a ZIP via `:zip`.

  Everything runs on in-memory buffers (T-014 guard): no temp files.
  """

  @doc """
  Splits a PDF and returns the output documents.

  ## Options

    * `:name` — output file stem, default `"part"` (outputs are numbered
      `part-001.pdf`, `part-002.pdf`, …)

  Returns `{:ok, [%{name: String.t(), bytes: binary()}]}` or
  `{:error, reason}`.
  """
  @spec split(binary(), tuple(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def split(bytes, mode, opts \\ []) when is_binary(bytes) do
    prefix = Keyword.get(opts, :name, "part")

    with {:ok, partitions} <- page_partitions(bytes, mode),
         {:ok, outputs} <- build_outputs(bytes, partitions, prefix) do
      {:ok, outputs}
    end
  end

  @doc """
  Computes the page partitions for a mode without touching the page bytes.

  Returns `{:ok, [[non_neg_integer()]]}` — each inner list is one output's
  page indices.
  """
  @spec page_partitions(binary(), tuple()) :: {:ok, [[non_neg_integer()]]} | {:error, term()}
  def page_partitions(bytes, {:every_n, n}) when is_integer(n) and n >= 1 do
    with {:ok, count} <- page_count(bytes) do
      partitions =
        0..(count - 1)
        |> Enum.to_list()
        |> Enum.chunk_every(n)
        |> Enum.reject(&(&1 == []))

      {:ok, partitions}
    end
  end

  def page_partitions(bytes, {:bookmarks, level}) when is_integer(level) and level >= 1 do
    with {:ok, doc} <- ExPdfium.open(bytes),
         {:ok, count} <- ExPdfium.page_count(doc),
         {:ok, outline} <- ExPdfium.outline(doc) do
      points =
        outline
        |> entries_at_level(level)
        |> Enum.map(& &1.page)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
        |> Enum.uniq()

      case points do
        [] -> {:error, {:no_bookmarks, level}}
        _ -> {:ok, build_segments(count, points)}
      end
    end
  end

  def page_partitions(bytes, {:ranges, groups}) when is_list(groups) do
    with {:ok, count} <- page_count(bytes) do
      result =
        Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, acc} ->
          indices =
            case group do
              %{from: a, to: b} when is_integer(a) and is_integer(b) ->
                Enum.to_list((a - 1)..(b - 1))

              list when is_list(list) ->
                list
            end

          if Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < count)) do
            {:cont, {:ok, acc ++ [indices]}}
          else
            {:halt, {:error, {:page_out_of_bounds, indices, count}}}
          end
        end)

      case result do
        {:ok, partitions} when partitions != [] -> {:ok, partitions}
        {:ok, []} -> {:error, :empty_ranges}
        {:error, _} = err -> err
      end
    end
  end

  def page_partitions(bytes, {:file_size, target}) when is_integer(target) and target > 0 do
    with {:ok, count} <- page_count(bytes),
         {:ok, sizes} <- measure_page_sizes(bytes, count) do
      {:ok, greedy_partitions(sizes, target)}
    end
  end

  def page_partitions(bytes, {:extract, pages}) when is_list(pages) do
    with {:ok, count} <- page_count(bytes) do
      if Enum.all?(pages, &(is_integer(&1) and &1 >= 0 and &1 < count)) do
        {:ok, Enum.map(pages, &[&1])}
      else
        {:error, {:page_out_of_bounds, pages, count}}
      end
    end
  end

  def page_partitions(_bytes, other), do: {:error, {:unknown_mode, other}}

  @doc """
  Parses a range-group spec for the ranges mode.

  Each comma-separated element becomes one output; elements may be a single
  page or an inclusive hyphen range (1-based). Example:
  `"1-3,5,7-9"` → three outputs.

  Returns `{:ok, [map() | [non_neg_integer()]]}` or
  `{:error, {message, spec}}`.
  """
  @spec parse_range_groups(String.t(), pos_integer()) ::
          {:ok, [map() | [non_neg_integer()]]} | {:error, {String.t(), String.t()}}
  def parse_range_groups(spec, page_count) when is_binary(spec) and is_integer(page_count) do
    trimmed = String.trim(spec)

    if trimmed == "" do
      {:error, {"no ranges given", spec}}
    else
      trimmed
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
        case parse_group(part, page_count) do
          {:ok, group} -> {:cont, {:ok, acc ++ [group]}}
          {:error, reason} -> {:halt, {:error, {reason, spec}}}
        end
      end)
    end
  end

  @doc """
  Packages output documents into a single in-memory ZIP.

  Returns `{:ok, zip_bytes}` or `{:error, reason}`.
  """
  @spec zip_outputs([map()], String.t()) :: {:ok, binary()} | {:error, term()}
  def zip_outputs(outputs, zip_name \\ "split.zip") when is_list(outputs) do
    entries =
      Enum.map(outputs, fn %{name: name, bytes: bytes} ->
        {String.to_charlist(name), bytes}
      end)

    case :zip.create(String.to_charlist(zip_name), entries, [:memory]) do
      {:ok, _name, zip_bytes} ->
        {:ok, zip_bytes}

      {:ok, {_name, zip_bytes}} ->
        {:ok, zip_bytes}

      {:error, reason} ->
        {:error, {:zip_failed, reason}}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp page_count(bytes) do
    with {:ok, doc} <- ExPdfium.open(bytes) do
      ExPdfium.page_count(doc)
    end
  end

  # Segments between split points: [0, p1) then [p1, p2) … [pn, count).
  defp build_segments(count, split_points) do
    [0 | split_points]
    |> Enum.concat([count])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] -> Enum.to_list(from..(to - 1)) end)
    |> Enum.reject(&(&1 == []))
  end

  # Collects outline entries at the given depth (1 = top level), preserving
  # tree order.
  defp entries_at_level(entries, 1), do: entries

  defp entries_at_level(entries, level) when level > 1 do
    Enum.flat_map(entries, fn entry ->
      entries_at_level(Map.get(entry, :children, []), level - 1)
    end)
  end

  # Measures each page's extracted-PDF size (one extraction at a time).
  defp measure_page_sizes(bytes, count) do
    with {:ok, doc} <- ExPdfium.open(bytes) do
      result =
        Enum.reduce_while(0..(count - 1), {:ok, []}, fn i, {:ok, acc} ->
          with {:ok, extracted} <- ExPdfium.extract_pages(doc, [i]),
               {:ok, out_bytes} <- ExPdfium.save_to_bytes(extracted) do
            {:cont, {:ok, acc ++ [byte_size(out_bytes)]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        {:ok, sizes} -> {:ok, sizes}
        {:error, _} = err -> err
      end
    end
  end

  # Greedy: accumulate pages until adding the next would exceed the target.
  defp greedy_partitions(sizes, target) do
    {parts, current, _cur_size} =
      sizes
      |> Enum.with_index()
      |> Enum.reduce({[], [], 0}, fn {size, idx}, {parts, current, cur_size} ->
        cond do
          current == [] ->
            {parts, [idx], size}

          cur_size + size > target ->
            {parts ++ [current], [idx], size}

          true ->
            {parts, current ++ [idx], cur_size + size}
        end
      end)

    if current == [], do: parts, else: parts ++ [current]
  end

  defp build_outputs(bytes, partitions, prefix) do
    with {:ok, doc} <- ExPdfium.open(bytes) do
      result =
        partitions
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {indices, i}, {:ok, acc} ->
          with {:ok, extracted} <- ExPdfium.extract_pages(doc, indices),
               {:ok, out_bytes} <- ExPdfium.save_to_bytes(extracted) do
            name = "#{prefix}-#{String.pad_leading(Integer.to_string(i), 3, "0")}.pdf"
            {:cont, {:ok, acc ++ [%{name: name, bytes: out_bytes}]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        {:ok, outputs} -> {:ok, outputs}
        {:error, _} = err -> err
      end
    end
  end

  defp parse_group(part, page_count) do
    case String.split(part, "-") do
      [single] ->
        with {:ok, n} <- parse_int(single) do
          if n > page_count do
            {:error, "page #{n} is out of range (document has #{page_count} pages)"}
          else
            {:ok, [n - 1]}
          end
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
              {:ok, %{from: a, to: b}}
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
end
