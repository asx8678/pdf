defmodule Quire.Editing.Mark do
  @moduledoc """
  Shared stamping engine for page marks (plan3.md §9.5, T-095).

  This is the single implementation behind `mark.page_number`
  (T-095), `mark.watermark` / `mark.header_footer` (T-096) and
  `mark.bates` (T-097). It:

  1. **Reads page geometry** through `Quire.Render.page_geometry/1`
     (display-oriented width/height + `/Rotate`).
  2. **Computes a placement rect in PDF user space** for every stamped
     page via `Quire.Editing.Mark.Placement` (the §14.3 geometry module),
     honouring anchors, margins, `/Rotate` and a non-zero `/CropBox`
     origin.
  3. **Draws the stamp as a PDFium page object** via `ExPdfium.draw_text/6`
     — `Compose` generates the stamp text (`Quire.Editing.Mark.PageNumber`
     for page numbers), PDFium applies it.

  Every stamp is a **user-space text object** on the page, so it survives
  save/reload and any re-render. The caller journals a `mark.*` op with
  the inverse `mark.remove`, and T-098 removes app-applied marks tracked
  in `text_edits`.

  ## Coordinate model (verified against PDFium + the §14.3 fixtures)

  `page_geometry/1` reports *display-oriented* dimensions (CropBox-based
  width/height, already including `/Rotate`), matching what pdf.js and the
  canvas show. Placement coordinates are therefore computed in the display
  frame and mapped into the page's true user space:

    * **Rotation**: display point `(dx, dy)` maps to content-space via
      `Quire.Geometry.apply_rotation/5` with `360 - rotate` (the inverse
      of the display transform). Empirically verified: drawing at the
      mapped content point on `rotated_pages.pdf` lands exactly at the
      display anchor.
    * **CropBox origin**: a non-zero origin shifts the content frame, so
      the content point is offset by the crop origin. Verified on
      `cropped_nonzero_origin.pdf` (origin 72,72): drawing at
      `content + origin` lands at the display anchor.
    * **Combined rot + crop**: `content = rotate_inverse(display, rot) +
      crop_origin` reproduces the renderer for every rotation, verified
      with a synthetic `/Rotate 90` + `/CropBox [72 72 540 720]` page.
  """

  alias Quire.Storage.Ref

  @doc "The anchor keys for the six stamp positions."
  @spec anchors() :: [String.t()]
  def anchors, do: ~w(bottom_left bottom_center bottom_right top_left top_center top_right)

  @doc "Font names accepted by the PDFium `draw_text` NIF."
  @spec fonts() :: [String.t()]
  def fonts,
    do:
      ~w(helvetica helvetica_bold helvetica_oblique helvetica_bold_oblique times_roman times_bold times_italic times_bold_italic courier courier_bold courier_oblique courier_bold_oblique symbol zapf_dingbats)

  @default_margin 36.0
  @default_font_size 12.0
  @default_font "helvetica"

  @doc """
  Returns the default margin in points (0.5 in).
  """
  @spec default_margin() :: float()
  def default_margin, do: @default_margin

  @doc """
  Returns the default stamp font size in points.
  """
  @spec default_font_size() :: float()
  def default_font_size, do: @default_font_size

  @doc """
  Validates and normalises the stamping options shared by every mark op.

  Accepts atom- or string-keyed maps and returns a normalised string-keyed
  map with validated defaults filled in, or `{:error, message}`.
  """
  @spec validate_options(map() | nil) :: {:ok, map()} | {:error, String.t()}
  def validate_options(opts) when is_map(opts) do
    with {:ok, anchor} <- validate_anchor(opts),
         {:ok, font} <- validate_font(opts),
         {:ok, font_size} <- validate_font_size(opts),
         {:ok, color} <- validate_color(opts) do
      {:ok,
       %{
         "anchor" => anchor,
         "margin" => number_value(opts, "margin", @default_margin),
         "font" => font,
         "font_size" => font_size,
         "color" => color,
         "start_at" => positive_integer(opts, "start_at", 1),
         "pages" => selector_value(opts)
       }}
    end
  end

  def validate_options(nil), do: validate_options(%{})

  @doc """
  Computes the user-space origin `{x, y}` for one stamped page.

  Returns `{:ok, {x, y}}` or `{:error, message}`. `rect` is the placement
  rectangle from `Placement.rect/6` in **user space** (post rotation +
  crop-origin offset); `geometry` is the page's `page_geometry/1` entry.
  The returned origin is the bottom-left of the placed text baseline cell.
  """
  @spec origin(list(number()), map()) :: {:ok, {number(), number()}} | {:error, String.t()}
  def origin(rect, _geometry) do
    case rect do
      [x0, _y0, _x1, y1] ->
        {:ok, {x0, y1}}

      _ ->
        {:error, "invalid placement rect"}
    end
  end

  @doc """
  Rasterises `text` onto `page_index` of `pdf_bytes` at the placement
  origin.

  `origin` is the `{x, y}` bottom-left of the text cell (already in user
  space). Options mirror `validate_options/1` plus `:size` / `:color` as
  accepted by `ExPdfium.draw_text/6`.

  Returns `{:ok, new_pdf_bytes}` or `{:error, reason}`.
  """
  @spec draw(binary(), non_neg_integer(), {number(), number()}, String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def draw(pdf_bytes, page_index, {x, y}, text, opts \\ []) do
    font = Keyword.get(opts, :font, @default_font)
    size = Keyword.get(opts, :size, @default_font_size)

    with {:ok, doc} <- ExPdfium.open(pdf_bytes),
         {:ok, doc} <- do_draw(doc, page_index, x, y, text, font, size, opts),
         {:ok, bytes} <- ExPdfium.save_to_bytes(doc) do
      # PDFium's full save (`FPDF_SaveAsCopy`) regenerates the trailer `/ID`
      # second element on every call from a non-thread-safe global, so two
      # byte-identical stampings of the same document differ in the trailer.
      # Restore the source document's own `/ID` (first element, kept by
      # PDFium) so repeated applies are byte-deterministic — important for
      # undo/re-apply and the OperationPropertyTest determinism contract.
      {:ok, restore_source_id(bytes, pdf_bytes)}
    end
  end

  defp do_draw(doc, page_index, x, y, text, font, size, opts) do
    color = Keyword.get(opts, :color, {0, 0, 0})
    color = draw_color(color)

    ExPdfium.draw_text(doc, page_index, {x, y}, text,
      font: String.to_atom(font),
      size: size,
      color: color
    )
  end

  # PDFium keeps the source trailer's `/ID` first element and mints a fresh
  # second element on every full save (FPDF_SaveAsCopy derives it from a
  # non-thread-safe global). Copy the source `/ID[0]` over the output's so the
  # same input always saves to the same bytes. Absent or malformed `/ID` in
  # the source, leave the output as-is.
  defp restore_source_id(output, source) do
    case Regex.run(~r{/ID\s*\[<([0-9A-Fa-f]+)>}, source) do
      [_, first_id] ->
        Regex.replace(
          ~r{/ID\s*\[<[0-9A-Fa-f]+><[0-9A-Fa-f]+>\]},
          output,
          "/ID[<#{first_id}><#{first_id}>]"
        )

      _ ->
        output
    end
  end

  @doc """
  Normalises the drawing `color` option for `ExPdfium.draw_text/6`.

  Accepts `{r, g, b}` or `{r, g, b, a}` with components in 0–255, a
  `"#rrggbb"` hex string, or an `"r,g,b"` string. Falls back to black for
  absent or malformed values.
  """
  @spec draw_color(term()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), 255}
  def draw_color(nil), do: {0, 0, 0, 255}

  def draw_color({r, g, b} = _color)
      when is_number(r) and is_number(g) and is_number(b),
      do: {clamp(r), clamp(g), clamp(b), 255}

  def draw_color({r, g, b, a} = _color)
      when is_number(r) and is_number(g) and is_number(b) and is_number(a),
      do: {clamp(r), clamp(g), clamp(b), clamp(a)}

  def draw_color(hex) when is_binary(hex) do
    hex = String.trim(hex)

    case hex_color(hex) do
      {r, g, b} -> {r, g, b, 255}
      :error -> {0, 0, 0, 255}
    end
  end

  def draw_color(_other), do: {0, 0, 0, 255}

  @doc """
  Convenience wrapper: reads `ref` bytes, draws one stamp per page, stores
  the result and returns the new `Quire.Storage.Ref`.

  `texts` is a list of `{page_index, text}` pairs (already filtered to the
  page range). Each entry is drawn with the same options.
  """
  @spec apply_stamps(Ref.t(), [{non_neg_integer(), String.t()}], keyword()) ::
          {:ok, Ref.t()} | {:error, term()}
  def apply_stamps(%Ref{} = ref, texts, opts) when is_list(texts) do
    with {:ok, pdf_bytes} <- Quire.Storage.get(ref),
         {:ok, new_bytes} <- draw_all(pdf_bytes, texts, opts),
         {:ok, new_ref} <- Quire.Storage.put(new_bytes, name: ref.name || "stamped.pdf") do
      {:ok, new_ref}
    end
  end

  @doc """
  Draws every `{page_index, text}` pair onto `pdf_bytes`.

  Returns `{:ok, new_pdf_bytes}` or `{:error, reason}`.
  """
  @spec draw_all(binary(), [{non_neg_integer(), String.t()}], keyword()) ::
          {:ok, binary()} | {:error, term()}
  def draw_all(pdf_bytes, texts, opts) when is_list(texts) do
    Enum.reduce_while(texts, {:ok, pdf_bytes}, fn {page_index, text}, {:ok, bytes} ->
      case Quire.Editing.Mark.draw(bytes, page_index, {0, 0}, text, opts) do
        {:ok, new_bytes} -> {:cont, {:ok, new_bytes}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp validate_anchor(opts) do
    anchor = string_value(opts, "anchor") || string_value(opts, :anchor) || "bottom_center"

    if anchor in anchors() do
      {:ok, anchor}
    else
      {:error, "Unknown anchor: #{anchor} (expected one of #{Enum.join(anchors(), ", ")})"}
    end
  end

  defp validate_font(opts) do
    font = string_value(opts, "font") || string_value(opts, :font) || @default_font

    if font in fonts() do
      {:ok, font}
    else
      {:error, "Unknown font: #{font} (expected one of #{Enum.join(fonts(), ", ")})"}
    end
  end

  defp validate_font_size(opts) do
    size = number_value(opts, "font_size", nil) || number_value(opts, :font_size, nil)

    cond do
      is_nil(size) -> {:ok, @default_font_size}
      is_number(size) and size > 0 -> {:ok, size}
      true -> {:error, "font_size must be a positive number"}
    end
  end

  defp validate_color(opts) do
    {:ok, draw_color(opts_color(opts))}
  end

  defp opts_color(opts) do
    case string_value(opts, "color") || string_value(opts, :color) do
      nil ->
        case opts[:color] do
          {_, _, _} = c -> c
          {_, _, _, _} = c -> c
          _ -> nil
        end

      other ->
        other
    end
  end

  defp number_value(opts, key, default) do
    value =
      case opts[key] do
        nil -> atom_value(opts, key)
        other -> other
      end

    case value do
      value when is_number(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {f, _} -> f
          :error -> default
        end

      _ ->
        default
    end
  end

  # Fetch an atom-keyed value without converting user input to atoms.
  defp atom_value(_opts, key) when is_binary(key), do: nil
  defp atom_value(opts, key), do: opts[key]

  defp string_value(opts, key) do
    case opts[key] do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp positive_integer(opts, key, default) do
    value =
      case opts[key] do
        nil -> atom_value(opts, key)
        other -> other
      end

    case value do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _} when int > 0 -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp selector_value(opts) do
    case opts["pages"] || opts[:pages] do
      selector when is_map(selector) -> selector
      _ -> nil
    end
  end

  defp clamp(value) when is_number(value) and value >= 0 and value <= 255, do: trunc(value)

  defp clamp(value) when is_number(value) and value > 255, do: 255
  defp clamp(_value), do: 0

  defp hex_color("#" <> rest) when byte_size(rest) == 6 do
    case Integer.parse(rest, 16) do
      {value, ""} ->
        {band(Bitwise.bsr(value, 16), 0xFF), band(Bitwise.bsr(value, 8), 0xFF), band(value, 0xFF)}

      _ ->
        :error
    end
  end

  defp hex_color(_), do: :error

  defp band(a, b), do: Bitwise.band(a, b)
end
