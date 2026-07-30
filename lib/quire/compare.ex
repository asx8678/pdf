defmodule Quire.Compare do
  @moduledoc """
  Document comparison engine for text and pixel diffs (§9.6, T-112).

  Compare two revisions of a document (or two separate documents) side by
  side.  Text diff aligns extracted spans via LCS and highlights
  insert/delete/change regions.  Pixel diff renders both pages at 150 DPI
  and computes a per-pixel difference map in Elixir.

  ## Entry points

      Quire.Compare.text(ref_a, ref_b, opts)  → {:ok, %TextDiff.Result{}}
      Quire.Compare.pixels(ref_a, ref_b, opts) → {:ok, %PixelDiff.Result{}}
  """

  alias Quire.Compare.{TextDiff, PixelDiff}

  @doc """
  Computes a text diff between two storage references.

  Options:
    - `page_range` — `{a_start..a_end, b_start..b_end}` (1‑based, default all)
    - `mode` — `:word` (default) or `:char`
  """
  @spec text(Storage.ref(), Storage.ref(), keyword()) ::
          {:ok, TextDiff.Result.t()} | {:error, String.t()}
  def text(ref_a, ref_b, opts \\ []) do
    TextDiff.compare(ref_a, ref_b, opts)
  end

  @doc """
  Computes a pixel diff between two storage references at 150 DPI.

  Options:
    - `page_range` — `{a_start..a_end, b_start..b_end}` (1‑based, default all)
  """
  @spec pixels(Storage.ref(), Storage.ref(), keyword()) ::
          {:ok, PixelDiff.Result.t()} | {:error, String.t()}
  def pixels(ref_a, ref_b, opts \\ []) do
    PixelDiff.compare(ref_a, ref_b, opts)
  end
end
