defmodule Quire.Compare.TextDiff do
  @moduledoc """
  Text diff for extracted PDF spans using LCS alignment.

  Compares two sets of per-page text spans (from `Quire.Render.extract_text/2`),
  aligns them by page and word, and produces a change list with
  insert/delete/change markers.

  ## Algorithm

  1. Extract text from both revisions.
  2. Align pages pairwise.
  3. Within each page, tokenise into words and run a Longest Common
     Subsequence (LCS) alignment via dynamic programming.
  4. Classify each token as unchanged/inserted/deleted.
  5. Merge consecutive same-class tokens into change spans.
  """

  defstruct [:pages, :changes]

  @type t :: %__MODULE__{
          pages: [PageDiff.t()],
          changes: [Change.t()]
        }

  defmodule PageDiff do
    @moduledoc """
    Diff for a single page pair.
    """
    defstruct [:page_a, :page_b, :changes]

    @type t :: %__MODULE__{
            page_a: non_neg_integer(),
            page_b: non_neg_integer(),
            changes: [Change.t()]
          }
  end

  defmodule Change do
    @moduledoc """
    A single diff change: a run of tokens in class `:insert`, `:delete`,
    or `:change`.
    """
    defstruct [:class, :text, :rects, :page_a, :page_b]

    @type t :: %__MODULE__{
            class: :inserted | :deleted | :change,
            text: String.t(),
            rects: [map()],
            page_a: non_neg_integer() | nil,
            page_b: non_neg_integer() | nil
          }
  end

  alias __MODULE__

  @doc """
  Computes a text diff between two storage references.

  Returns `{:ok, %TextDiff{}}` with per-page and flattened change lists.
  """
  @spec compare(Storage.ref(), Storage.ref(), keyword()) ::
          {:ok, t()} | {:error, String.t()}
  def compare(ref_a, ref_b, _opts \\ []) do
    with {:ok, pages_a} <- Quire.Render.extract_text(ref_a, []),
         {:ok, pages_b} <- Quire.Render.extract_text(ref_b, []) do
      page_diffs = diff_pages(pages_a, pages_b)
      all_changes = Enum.flat_map(page_diffs, & &1.changes)

      {:ok, %TextDiff{pages: page_diffs, changes: all_changes}}
    end
  end

  @doc """
  Computes a text diff directly from previously-extracted page data.
  """
  @spec compare_pages(list(), list()) :: t()
  def compare_pages(pages_a, pages_b) do
    page_diffs = diff_pages(pages_a, pages_b)
    all_changes = Enum.flat_map(page_diffs, & &1.changes)
    %TextDiff{pages: page_diffs, changes: all_changes}
  end

  # ── Page alignment ─────────────────────────────────────────────────────

  defp diff_pages(pages_a, pages_b) do
    max_count = max(length(pages_a), length(pages_b))

    0..(max_count - 1)//1
    |> Enum.reduce([], fn i, acc ->
      a = Enum.at(pages_a, i)
      b = Enum.at(pages_b, i)

      if is_nil(a) or is_nil(b) do
        acc
      else
        changes = align_spans(a.spans || [], b.spans || [])

        [
          %PageDiff{page_a: i, page_b: i, changes: changes}
          | acc
        ]
      end
    end)
    |> Enum.reverse()
  end

  # ── Span → tokens → LCS → changes ─────────────────────────────────────

  defp align_spans(spans_a, spans_b) do
    tokens_a = spans_to_tokens(spans_a)
    tokens_b = spans_to_tokens(spans_b)

    alignment = lcs(tokens_a, tokens_b)

    alignment
    |> classify_changes()
    |> merge_runs()
  end

  defp spans_to_tokens(spans) do
    Enum.flat_map(spans, fn span ->
      (span.text || "")
      |> String.split(~r{[\s]+}, include_captures: false)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn word ->
        %{text: word, rect: span.bounds, page: span.page_index}
      end)
    end)
  end

  # ── LCS via DP (pure Elixir, map-based table) ─────────────────────────

  defp lcs([], _b), do: Enum.map(_b, &{:right, &1})
  defp lcs(a, []), do: Enum.map(a, &{:left, &1})
  defp lcs([], []), do: []

  defp lcs(a, b) do
    n = length(a)
    m = length(b)

    table = build_table(a, b, n, m)

    backtrack(table, a, b, n, m, [])
    |> Enum.reverse()
  end

  defp build_table(_a, _b, 0, _m), do: %{}
  defp build_table(_a, _b, _n, 0), do: %{}

  defp build_table(a, b, n, m) do
    table = %{{0, 0} => 0}

    table =
      Enum.reduce(1..n, table, fn i, tbl ->
        Map.put(tbl, {i, 0}, 0)
      end)

    table =
      Enum.reduce(1..m, table, fn j, tbl ->
        Map.put(tbl, {0, j}, 0)
      end)

    Enum.reduce(1..n, table, fn i, tbl ->
      Enum.reduce(1..m, tbl, fn j, t ->
        a_val = Enum.at(a, i - 1)
        b_val = Enum.at(b, j - 1)

        val =
          if token_match?(a_val, b_val) do
            t[{i - 1, j - 1}] + 1
          else
            max(t[{i - 1, j}] || 0, t[{i, j - 1}] || 0)
          end

        Map.put(t, {i, j}, val)
      end)
    end)
  end

  defp backtrack(_table, _a, _b, 0, 0, acc), do: acc

  defp backtrack(table, a, b, i, j, acc) do
    cond do
      i > 0 and j > 0 and token_match?(Enum.at(a, i - 1), Enum.at(b, j - 1)) ->
        backtrack(table, a, b, i - 1, j - 1, [{:same, Enum.at(a, i - 1)} | acc])

      j > 0 and (i == 0 || (table[{i, j - 1}] || 0) >= (table[{i - 1, j}] || 0)) ->
        backtrack(table, a, b, i, j - 1, [{:right, Enum.at(b, j - 1)} | acc])

      i > 0 ->
        backtrack(table, a, b, i - 1, j, [{:left, Enum.at(a, i - 1)} | acc])

      true ->
        acc
    end
  end

  # ── Token helpers ──────────────────────────────────────────────────────

  defp token_match?(a, b) do
    String.downcase(strip_punct(a.text)) == String.downcase(strip_punct(b.text))
  end

  defp strip_punct(text) do
    String.replace(text, ~r/[^a-zA-Z0-9\s]/, "")
  end

  # ── Classification ─────────────────────────────────────────────────────

  defp classify_changes(alignment) do
    Enum.map(alignment, fn
      {:same, tok} -> {:unchanged, tok}
      {:left, tok} -> {:deleted, tok}
      {:right, tok} -> {:inserted, tok}
    end)
  end

  # ── Run merging ────────────────────────────────────────────────────────

  defp merge_runs(classified) do
    classified
    |> Enum.chunk_by(fn {class, _tok} -> class end)
    |> Enum.map(fn group ->
      {class, _} = hd(group)

      if class == :unchanged do
        nil
      else
        text = Enum.map_join(group, " ", fn {_c, tok} -> tok.text end)

        %Change{
          class: class,
          text: String.trim(text),
          rects: Enum.map(group, fn {_c, tok} -> tok.rect end) |> Enum.uniq(),
          page_a: Enum.find_value(group, fn {_c, tok} -> tok.page end),
          page_b: Enum.find_value(group, fn {_c, tok} -> tok.page end)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
