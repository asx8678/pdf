defmodule Quire.Editor.RunRewriter do
  @moduledoc """
  Content‑stream rewrite helper for Edit mode (T-091).

  Takes an identified `run` (from `Quire.Editor.RunIdentifier`) and a new
  text string, and produces a PDF content‑stream fragment using
  `Quire.Compose.Primitives.text_object/4`.

  The generated stream preserves the run's font family, size, and
  position (baseline origin). Colour is emitted as a grayscale or RGB
  operator that matches the run's stored colour.

  ## Usage

      {:ok, stream} = Quire.Editor.RunRewriter.rewrite_run(run, "replacement text",
        page_width: 612.0, page_height: 792.0)
  """

  alias Quire.Compose.Primitives
  alias Quire.Engine

  @doc """
  Rewrites a text run's content stream with `new_text`.

  Preserves the original run's font name, font size, and baseline
  position. Returns a content‑stream iodata fragment suitable for
  inclusion in a page's content stream.

  ## Options

    * `:page_width`, `:page_height` — PDF page dimensions in points
      (defaults to A4: 595.28 × 841.89)
    * `:color` — override colour string (e.g. `"0 g"` for black,
      `"0 0 0 rg"` for RGB black); defaults to a grayscale operator
      derived from the run's `:color` field
    * `:font` — override font name; defaults to the run's `:font_name`
    * `:font_size` — override font size; defaults to the run's `:font_size`
    * `:x`, `:y` — override position in PDF points; defaults to the
      baseline‑aligned left edge of the run's bounding box

  ## Returns

    * `{:ok, iodata}` — the content‑stream operators
    * `{:error, %Engine.Error{}}` — if position or text validation fails
  """
  @spec rewrite_run(map(), String.t(), keyword()) ::
          {:ok, IO.iodata()} | {:error, Engine.Error.t()}
  def rewrite_run(run, new_text, opts \\ []) do
    page_w = Keyword.get(opts, :page_width, 595.28)
    page_h = Keyword.get(opts, :page_height, 841.89)

    x = Keyword.get(opts, :x, run.bbox |> then(fn [x0, _y0, _x1, _y1] -> x0 end))
    y = Keyword.get(opts, :y, run[:baseline_y] || run.bbox |> then(fn [_, y0, _, _] -> y0 end))

    font = Keyword.get(opts, :font, map_font_name(run.font_name))
    font_size = Keyword.get(opts, :font_size, run.font_size)
    colour = Keyword.get(opts, :color, colour_operator(run))

    Primitives.text_object(new_text, x, y,
      font: font,
      font_size: font_size,
      color: colour,
      page_width: page_w,
      page_height: page_h
    )
  end

  @doc """
  Composes a content stream from a list of runs.

  Each run in `runs` is rewritten with the corresponding text from
  `texts` (same index). Returns a single combined content‑stream fragment
  via `Primitives.compose/1`.

  ## Options

    Same as `rewrite_run/3`, applied per‑run unless overridden.
  """
  @spec rewrite_runs([map()], [String.t()], keyword()) ::
          {:ok, IO.iodata()} | {:error, Engine.Error.t()}
  def rewrite_runs(runs, texts, opts \\ []) when is_list(runs) and is_list(texts) do
    if length(runs) != length(texts) do
      {:error,
       %Engine.Error{
         engine: __MODULE__,
         operation: :rewrite_runs,
         code: :invalid_argument,
         message: "runs and texts must have the same length",
         detail: nil
       }}
    else
      results =
        Enum.zip(runs, texts)
        |> Enum.map(fn {run, text} -> rewrite_run(run, text, opts) end)

      Primitives.compose(results)
    end
  end

  # ── Font mapping ─────────────────────────────────────────────────────────

  @doc false
  # Maps a PDF internal font name to a standard-14 name suitable for
  # `Quire.Compose.Primitives.text_object/4`. The primitive uses the
  # font name directly in `/Tf`, so we pass through the base name.
  def map_font_name(font_name) do
    font_name
    |> Quire.Editor.RunIdentifier.normalize_font_name()
    |> strip_weight_suffix()
  end

  defp strip_weight_suffix(name) do
    # Strip common weight/style suffixes for /Tf; the primitive just
    # passes the string through so this is cosmetic.
    name
    |> String.replace(~r/- (Bold|Italic|Oblique)(Bold|Italic|Oblique)?$/i, "")
    |> String.trim()
  end

  # ── Colour operators ─────────────────────────────────────────────────────

  @doc false
  # Converts the run's colour field to a PDF colour operator string.
  # The run stores colour as `[r, g, b]` with 0.0–1.0 floats.
  def colour_operator(%{color: [r, g, b]}) do
    "#{format_rgb(r)} #{format_rgb(g)} #{format_rgb(b)} rg"
  end

  def colour_operator(%{color: [k]}) do
    "#{format_rgb(k)} g"
  end

  def colour_operator(_), do: "0 g"

  defp format_rgb(v) when is_float(v), do: :erlang.float_to_binary(v, [:compact, decimals: 4])
  defp format_rgb(v) when is_integer(v), do: Integer.to_string(v)
end
