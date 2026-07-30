defmodule Quire.Compare.PixelDiff do
  @moduledoc """
  Visual pixel diff between two PDF pages.

  Renders both pages at a configurable DPI (default 150) via the PDFium NIF,
  then computes a per-pixel difference map in Elixir.

  The result highlights every pixel that differs.  A changed-region summary
  groups adjacent differing pixels into bounding boxes.
  """

  defstruct [:pages, :total_diff_pixels, :total_pixels]

  @type t :: %__MODULE__{
          pages: [PagePixelDiff.t()],
          total_diff_pixels: non_neg_integer(),
          total_pixels: non_neg_integer()
        }

  defmodule PagePixelDiff do
    @moduledoc """
    Pixel diff for a single page pair.
    """
    defstruct [:page_a, :page_b, :diff_pixels, :total_pixels, :diff_map, :changed_regions]

    @type t :: %__MODULE__{
            page_a: non_neg_integer(),
            page_b: non_neg_integer(),
            diff_pixels: non_neg_integer(),
            total_pixels: non_neg_integer(),
            diff_map: binary() | nil,
            changed_regions: [map()]
          }
  end

  alias __MODULE__

  @default_dpi 150

  @doc """
  Computes a pixel diff between two storage references.

  Options:
    - `dpi` — render resolution (default: 150)
    - `page_range` — `{a_start..a_end, b_start..b_end}` (1‑based, default all)
  """
  @spec compare(Storage.ref(), Storage.ref(), keyword()) ::
          {:ok, t()} | {:error, String.t()}
  def compare(ref_a, ref_b, opts \\ []) do
    dpi = Keyword.get(opts, :dpi, @default_dpi)

    with {:ok, pages_a} <- page_count(ref_a),
         {:ok, pages_b} <- page_count(ref_b) do
      max_pages = max(pages_a, pages_b)

      {page_diffs, total_diff, total_all} =
        Enum.reduce(0..(max_pages - 1)//1, {[], 0, 0}, fn i, {acc, diff_sum, total_sum} ->
          a =
            if i < pages_a do
              render_page_raw(ref_a, i, dpi)
            else
              {:error, :no_page}
            end

          b =
            if i < pages_b do
              render_page_raw(ref_b, i, dpi)
            else
              {:error, :no_page}
            end

          page_result = diff_page(i, i, a, b)
          {[page_result | acc], diff_sum + page_result.diff_pixels,
           total_sum + page_result.total_pixels}
        end)

      {:ok, %PixelDiff{
        pages: Enum.reverse(page_diffs),
        total_diff_pixels: total_diff,
        total_pixels: total_all
      }}
    end
  end

  # ── Page diff ──────────────────────────────────────────────────────────

  defp diff_page(page_a, page_b, {:ok, bitmap_a}, {:ok, bitmap_b}) do
    diff = compute_diff(bitmap_a, bitmap_b)
    regions = find_changed_regions(diff, bitmap_a.width)

    %PagePixelDiff{
      page_a: page_a,
      page_b: page_b,
      diff_pixels: count_diff_pixels(diff),
      total_pixels: bitmap_a.width * bitmap_a.height,
      diff_map: diff,
      changed_regions: regions
    }
  end

  defp diff_page(page_a, page_b, _a, _b) do
    %PagePixelDiff{
      page_a: page_a,
      page_b: page_b,
      diff_pixels: 0,
      total_pixels: 0,
      diff_map: nil,
      changed_regions: []
    }
  end

  # ── Raw bitmap rendering (bypasses PNG conversion) ────────────────────

  defp render_page_raw(ref, page_num, dpi) do
    with {:ok, bytes} <- Quire.Storage.get(ref),
         {:ok, doc} <- ExPdfium.open(bytes) do
      try do
        ExPdfium.render_page(doc, page_num, dpi: dpi)
      after
        ExPdfium.close(doc)
      end
    end
  end

  defp page_count(ref) do
    with {:ok, bytes} <- Quire.Storage.get(ref),
         {:ok, doc} <- ExPdfium.open(bytes) do
      try do
        ExPdfium.page_count(doc)
      after
        ExPdfium.close(doc)
      end
    end
  end

  # ── Pixel-level comparison ─────────────────────────────────────────────

  @doc false
  def compute_diff(%ExPdfium.Bitmap{data: a, width: w, height: h}, %ExPdfium.Bitmap{
         data: b,
         width: w,
         height: h
       }) do
    # Per-pixel comparison: zip aligned triplets via tail recursion.
    do_compute_diff(a, b, <<>>)
  end

  defp do_compute_diff(<<r1, g1, b1, ra::binary>>, <<r2, g2, b2, rb::binary>>, acc) do
    val =
      if abs(r1 - r2) > 10 or abs(g1 - g2) > 10 or abs(b1 - b2) > 10 do
        255
      else
        0
      end

    do_compute_diff(ra, rb, <<acc::binary, val>>)
  end

  defp do_compute_diff(<<>>, <<>>, acc), do: acc

  def compute_diff(a_bitmap, b_bitmap) do
    # Mismatched dimensions — treat as entirely different
    byte_size(a_bitmap.data) |> then(&:binary.copy(<<255>>, &1))
  end

  # ── Diff pixel counting ───────────────────────────────────────────────

  defp count_diff_pixels(diff_map) do
    # Count non-zero bytes (differing pixels)
    for <<p::8 <- diff_map>>, p != 0, reduce: 0 do
      acc -> acc + 1
    end
  end

  # ── Changed region detection ───────────────────────────────────────────

  @doc false
  def find_changed_regions(diff_map, width) when is_binary(diff_map) do
    height = div(byte_size(diff_map), width)

    # Find changed rows and columns, then merge into bounding boxes.
    # Uses a row-scan approach rather than flood fill to avoid stack depth issues
    # on large connected regions.
    changed_rows =
      0..(height - 1)//1
      |> Enum.filter(fn y ->
        row_start = y * width
        binary_part(diff_map, row_start, width) |> :binary.bin_to_list() |> Enum.any?(&(&1 != 0))
      end)
      |> group_consecutive()

    # For each row band, find changed columns
    Enum.map(changed_rows, fn {y_start, y_end} ->
      # Find the extent of horizontal change across these rows
      {x_min, x_max} =
        Enum.reduce(y_start..y_end//1, {width, 0}, fn y, {min_x, max_x} ->
          row_start = y * width

          {row_min, row_max} =
            binary_part(diff_map, row_start, width)
            |> :binary.bin_to_list()
            |> Enum.with_index()
            |> Enum.filter(fn {p, _} -> p != 0 end)
            |> Enum.reduce({width, 0}, fn {_p, x}, {rmn, rmx} -> {min(rmn, x), max(rmx, x)} end)

          {min(min_x, row_min), max(max_x, row_max)}
        end)

      %{
        x: x_min,
        y: y_start,
        width: max(0, x_max - x_min + 1),
        height: y_end - y_start + 1
      }
    end)
    |> Enum.reject(&(&1.width == 0 or &1.height == 0))
  end

  def find_changed_regions(nil, _width), do: []

  defp group_consecutive([]), do: []

  defp group_consecutive([first | rest]) do
    do_group(rest, first, first, [])
    |> Enum.reverse()
  end

  defp do_group([], current, start, acc), do: [{start, current} | acc]

  defp do_group([n | rest], current, start, acc) when n == current + 1 do
    do_group(rest, n, start, acc)
  end

  defp do_group([n | rest], _current, start, acc) do
    do_group(rest, n, n, [{start, _current} | acc])
  end

  @doc """
  Returns the fraction of differing pixels (0.0 — 1.0).
  """
  @spec diff_ratio(t()) :: float()
  def diff_ratio(%PixelDiff{total_pixels: 0}), do: 0.0

  def diff_ratio(%PixelDiff{total_diff_pixels: diff, total_pixels: total}) do
    diff / total
  end
end
