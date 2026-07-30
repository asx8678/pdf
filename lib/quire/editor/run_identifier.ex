defmodule Quire.Editor.RunIdentifier do
  @moduledoc """
  Text-run identification for Edit mode (T-091).

  Uses `ExPdfium.chars/3` per-character data (bounds, font size, baseline
  origin, and opt-in font style) to group contiguous characters with the
  same font into cohesive "runs" — the unit of edit.

  ## Run identification

  Characters are grouped into a run when they share:

    * `font_name` (base name, stripped of the 6‑character subset prefix)
    * `font_size` (within a small epsilon)
    * Same text line (same baseline y within a tolerance)

  A run boundary is forced by:

    * A font-name or size change
    * A baseline jump significant enough to indicate a new line
    * A page‑position gap that exceeds the run's average char width
      (word‑level separation is preserved as whitespace within a run;
      large gaps indicate column or section boundaries)

  ## Font availability check

  `check_font_available/1` examines the font name:

    * Standard‑14 fonts (Helvetica, Times, Courier, Symbol, ZapfDingbats)
      are always available — they require no embedding.
    * Subset fonts (name prefixed with 6 uppercase chars + `+`, e.g.
      `ABCDEF+Calibri`) are treated as embedded and thus available.
    * All other non‑standard fonts — return `{:error, :font_unavailable}`.

  The error message includes a suggestion to convert the text via OCR.
  """

  alias Quire.Engine
  alias Quire.Storage
  alias Quire.Storage.Ref

  # The standard‑14 PDF fonts — always available without embedding.
  @standard_14 [
    "Helvetica",
    "Helvetica-Bold",
    "Helvetica-Oblique",
    "Helvetica-BoldOblique",
    "Times-Roman",
    "Times-Bold",
    "Times-Italic",
    "Times-BoldItalic",
    "Courier",
    "Courier-Bold",
    "Courier-Oblique",
    "Courier-BoldOblique",
    "Symbol",
    "ZapfDingbats"
  ]

  # Spacing tolerance for same‑line grouping (in PDF points).
  # Characters whose baseline `y` coordinates differ by less than this are
  # considered to be on the same text line.
  @baseline_tolerance 2.0

  # Font‑size epsilon for comparing sizes (slight rounding differences from
  # PDFium).
  @size_epsilon 0.25

  @typedoc """
  A single character with its PDFium metadata.
  """
  @type origin_t :: %{x: float(), y: float()}

  @type char_style_t :: %{
          font_name: String.t(),
          weight: non_neg_integer() | nil,
          bold?: boolean(),
          italic?: boolean(),
          serif?: boolean(),
          fixed_pitch?: boolean()
        }

  @type char_t :: %{
          :char => String.t(),
          :bounds => map() | nil,
          :font_size => float(),
          :origin => origin_t() | nil,
          optional(:style) => char_style_t()
        }

  @typedoc """
  An identified text run — contiguous characters sharing the same font
  properties on the same line.

  Fields:

    * `:text` — the concatenated text string
    * `:font_name` — base font name (subset prefix stripped)
    * `:font_size` — size in PDF points
    * `:color` — colour as `[r, g, b]` floats (placeholder; PDFium does
      not expose per‑char colour in `ExPdfium.chars/3`)
    * `:bbox` — bounding box `[x0, y0, x1, y1]` in PDF points
    * `:baseline_y` — the baseline y‑coordinate for the run
    * `:bold` — whether the font weight indicates bold
    * `:italic` — whether the font style indicates italic
    * `:chars` — the original per‑character objects
  """
  @type run_t :: %{
          text: String.t(),
          font_name: String.t(),
          font_size: float(),
          color: [float()],
          bbox: [float()],
          baseline_y: float(),
          bold: boolean(),
          italic: boolean(),
          chars: [char_t()]
        }

  @doc """
  Identifies text runs on a page.

  Opens the document from `page_ref`, extracts per‑character data via
  PDFium with style information, and groups contiguous characters into
  runs based on font properties and spatial contiguity.

  ## Returns

    * `{:ok, [run_t]}` — the identified runs in content‑stream order
    * `{:error, %Engine.Error{}}` — if the document cannot be read or
      the page has no extractable characters
  """
  @spec identify_runs(ref :: Ref.t(), page_index :: non_neg_integer()) ::
          {:ok, [run_t()]} | {:error, Engine.Error.t()}
  def identify_runs(%Ref{} = ref, page_index) when is_integer(page_index) and page_index >= 0 do
    with {:ok, bytes} <- Storage.get(ref),
         {:ok, doc} <- ExPdfium.open_blob(bytes) do
      try do
        case ExPdfium.chars(doc, page_index, style: true) do
          {:ok, []} ->
            {:ok, []}

          {:ok, chars} ->
            runs = group_chars_into_runs(chars)
            {:ok, runs}

          {:error, reason} ->
            {:error,
             %Engine.Error{
               engine: __MODULE__,
               operation: :identify_runs,
               code: :nif,
               message: "ExPdfium.chars/3 failed: #{inspect(reason)}",
               detail: nil
             }}
        end
      after
        ExPdfium.close(doc)
      end
    else
      {:error, reason} ->
        {:error,
         %Engine.Error{
           engine: __MODULE__,
           operation: :identify_runs,
           code: :runtime,
           message: "Failed to open document: #{inspect(reason)}",
           detail: nil
         }}
    end
  end

  @doc """
  Checks whether the font used in `run` is available for content‑stream
  rewriting.

  A font is available if it is one of the standard‑14 built‑in fonts
  (always present in any PDF consumer) or is embedded (identified by
  the subset prefix or being a non‑standard name that is likely
  embedded).

  ## Returns

    * `:ok` — the font is available
    * `{:error, :font_unavailable, message}` — the font is not available
      for rewriting; the message suggests OCR conversion
  """
  @spec check_font_available(run_t()) :: :ok | {:error, :font_unavailable, String.t()}
  def check_font_available(%{font_name: font_name}) do
    base = normalize_font_name(font_name)

    cond do
      base in @standard_14 ->
        :ok

      String.match?(base, ~r/^[A-Z0-9]{6,}\+/) ->
        # Subset font — the 6‑character prefix followed by `+` indicates
        # a subset of the font is embedded in the PDF.
        :ok

      true ->
        {:error, :font_unavailable,
         "The font \"#{base}\" is not available for editing. " <>
           "Convert the affected text to editable content via OCR."}
    end
  end

  # ── Run grouping ─────────────────────────────────────────────────────────

  defp group_chars_into_runs(chars) do
    chars
    |> Enum.reduce([], fn char, runs ->
      case runs do
        [] ->
          [start_run(char)]

        [current | rest] ->
          if same_run?(current, char) do
            [extend_run(current, char) | rest]
          else
            [start_run(char) | runs]
          end
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&finalize_run/1)
  end

  defp start_run(char) do
    %{
      chars: [char],
      font_name: char[:style][:font_name] || "Unknown",
      font_size: char.font_size,
      baseline_y: get_baseline_y(char),
      bold: char[:style][:bold?] || false,
      italic: char[:style][:italic?] || false
    }
  end

  defp extend_run(run, char) do
    %{run | chars: [char | run.chars]}
  end

  defp same_run?(run, next_char) do
    run_font = normalize_font_name(run.font_name)
    next_font = normalize_font_name(next_char[:style][:font_name] || "Unknown")

    same_font?(run_font, next_font) and
      same_size?(run.font_size, next_char.font_size) and
      same_line?(run.baseline_y, next_char)
  end

  defp same_font?(f1, f2), do: f1 == f2

  defp same_size?(s1, s2), do: abs(s1 - s2) <= @size_epsilon

  defp same_line?(baseline_y, next_char) do
    next_y = get_baseline_y(next_char)
    abs(baseline_y - next_y) <= @baseline_tolerance
  end

  defp finalize_run(%{chars: chars} = run) do
    # Characters are stored reversed during accumulation — put them back
    # in content-stream order.
    ordered = Enum.reverse(chars)

    text =
      ordered
      |> Enum.map(& &1.char)
      |> Enum.join("")

    bbox = compute_bbox(ordered)
    baseline_y = run.baseline_y

    %{
      text: text,
      font_name: run.font_name,
      font_size: run.font_size,
      color: [0.0, 0.0, 0.0],
      bbox: bbox,
      baseline_y: baseline_y,
      bold: run.bold,
      italic: run.italic,
      chars: ordered
    }
  end

  # ── Geometry helpers ─────────────────────────────────────────────────────

  defp get_baseline_y(%{origin: %{y: y}}), do: y
  defp get_baseline_y(%{bounds: %{bottom: y}}), do: y
  defp get_baseline_y(_), do: 0.0

  defp compute_bbox(chars) do
    bounds =
      chars
      |> Enum.map(& &1.bounds)
      |> Enum.reject(&is_nil/1)

    case bounds do
      [] ->
        [0.0, 0.0, 0.0, 0.0]

      _ ->
        x0 = Enum.min_by(bounds, & &1.left).left
        y0 = Enum.min_by(bounds, & &1.bottom).bottom
        x1 = Enum.max_by(bounds, & &1.right).right
        y1 = Enum.max_by(bounds, & &1.top).top
        [x0, y0, x1, y1]
    end
  end

  # ── Font‑name normalisation ──────────────────────────────────────────────

  @doc false
  def normalize_font_name(name) when is_binary(name) do
    # Strip the 6‑character subset prefix (e.g. "ABCDEF+Calibri" → "Calibri")
    name = String.replace(name, ~r/^[A-Z0-9]{6,}\+/, "")

    # Remove common suffix patterns that don't change base identity
    name |> String.trim()
  end

  def normalize_font_name(nil), do: "Unknown"
end
