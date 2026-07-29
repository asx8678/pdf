defmodule Quire.Pdf.AcroForm do
  @moduledoc """
  AcroForm field operations: appearance-stream generation.

  ## Appearance-stream generation

  PDFium's form-field setter writes `/V` but never regenerates `/AP`.
  `ExPdfium.flatten/1` bakes `/AP` and ignores `/V` entirely. So a value-only
  fill through `flatten/1` produces the *old* or empty appearance and silently
  discards what the user typed.

  **Hard rule (ADR 0003 D5):** any `/V` write MUST also write `/AP` before the
  document is flattened or rasterised by anything other than `render_page/3`.
  Call `generate_appearances/1` after writing field values and before flattening.

  Checkbox and radio fields do NOT need appearance regeneration — their
  appearances are pre-baked per state under `/AP /N`, and PDFium switches `/AS`
  along with the value, so flattening bakes the correct state.

  Text fields bear the full cost of this gap: generating a text appearance
  stream means parsing `/DA`, measuring text extents and emitting content-stream
  operators. This module handles the common case.

  ## Fork alternative: `FPDFAnnot_SetAP`

  PDFium's own escape hatch for supplying an appearance, `FPDFAnnot_SetAP`, IS on
  the public `pdfium-render` `PdfiumLibraryBindings` trait — but every raw
  `FPDF_ANNOTATION` / `FPDF_PAGE` / `FPDF_DOCUMENT` accessor in
  `pdfium-render` is `pub(crate)`, so a downstream NIF crate cannot obtain the
  handles to call it.

  If the upstream ex_pdfium patch (pdf-8v5b) or a future upstream release exposes
  annotation handles, `FPDFAnnot_SetAP` becomes the faster option for text fields
  and the *only* option for rich-text fields. Until then, generating the
  appearance stream through the PDF object model (`Quire.Pdf`) is the correct
  path, as assigned by ADR 0003 D5.
  """

  alias Quire.Pdf

  @margin 2.0
  @default_da "/Helv 12 Tf 0 g"

  @doc """
  Generate `/AP` / `/N` (normal) appearance streams for every form field in the
  document that has a `/V` value.

  For text fields (`/FT` = `/Tx`), produces a Form XObject whose content stream
  renders the field's current value using the font, size and colour declared in
  the widget's `/DA` string. The resulting appearance is written in place on the
  widget dictionary so that `ExPdfium.flatten/1` bakes the correct content.

  Fields with no `/V`, or whose `/V` is empty, are skipped. Checkbox / radio /
  list / button fields are skipped because PDFium's own setter already handles
  them correctly.

  ## Resource handling

  The generated appearance references fonts from the AcroForm's `/DR` / `/Font`
  dictionary when available. If the font is not found there, the appearance uses
  the font name as a standard PDF font name (e.g. `Helv`, `TiRo`, `CoBo`).

  ## Limitations

  - Only merged field-widget objects are handled (field and widget in one
    dictionary). Multi-widget fields (`/Kids`) are not supported yet.
  - Multi-line, comb, password and rich-text fields use a simplified single-line
    appearance.
  - Text alignment (left/center/right) is not implemented; text is always flush
    left with a 2pt margin.
  - The `/DA` colour specification is passed through, but the appearance always
    emits a black fill / white background as a safe default.
  """
  @spec generate_appearances(Pdf.t()) :: :ok | {:error, atom()}
  def generate_appearances(doc) when is_reference(doc) do
    with {:ok, catalog} <- Pdf.catalog(doc),
         {:ok, acroform_ref} <- ref_from_dict(catalog, "/AcroForm"),
         {:ok, acroform} <- Pdf.get_object(doc, acroform_ref) do
      fields = Map.get(acroform, "/Fields", [])

      # Extract AcroForm's /DR /Font for resource resolution
      acroform_fonts =
        acroform
        |> Map.get("/DR", %{})
        |> Map.get("/Font", %{})

      fields
      |> List.wrap()
      |> Enum.reduce_while(:ok, fn
        {:ref, _num, _gen} = ref, :ok ->
          case generate_field_appearance(doc, ref, acroform_fonts) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end

        _, :ok ->
          {:cont, :ok}
      end)
    end
  end

  # ── Field walk ──────────────────────────────────────────────────────────────

  defp generate_field_appearance(doc, field_ref, acroform_fonts) do
    field_id = ref_to_id(field_ref)

    with {:ok, field} <- Pdf.get_object(doc, field_id) do
      field_type = Map.get(field, "/FT")
      value = Map.get(field, "/V")

      cond do
        # Text field with a non-empty string value
        field_type == {:name, "Tx"} and is_binary(value) and byte_size(value) > 0 ->
          # Check for kids (multi-widget fields — each kid gets its own /AP)
          case Map.get(field, "/Kids") do
            kids when is_list(kids) and kids != [] ->
              parent_da = Map.get(field, "/DA")

              Enum.reduce_while(kids, :ok, fn
                {:ref, _, _} = kid_ref, :ok ->
                  kid_id = ref_to_id(kid_ref)

                  with {:ok, kid} <- Pdf.get_object(doc, kid_id) do
                    # Kid inherits /DA from parent if not set on itself
                    kid_da = Map.get(kid, "/DA", parent_da)
                    kid = if kid_da, do: Map.put(kid, "/DA", kid_da), else: kid
                    write_text_appearance(doc, kid, value, kid_id, acroform_fonts)
                  else
                    {:error, :not_found} -> {:cont, :ok}
                    {:error, _} = err -> {:halt, err}
                  end

                _, :ok ->
                  {:cont, :ok}
              end)

            _ ->
              write_text_appearance(doc, field, value, field_id, acroform_fonts)
          end

        true ->
          :ok
      end
    else
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Text appearance generation ──────────────────────────────────────────────

  defp write_text_appearance(doc, widget, value, widget_id, acroform_fonts) do
    # Widget rect — default to a reasonable size if missing
    rect = Map.get(widget, "/Rect", [0, 0, 100, 20])

    [llx, lly, urx, ury] =
      rect
      |> List.wrap()
      |> Enum.map(&to_float/1)

    width = max(urx - llx, 1.0)
    height = max(ury - lly, 1.0)

    # Parse /DA: "/Helv 12 Tf 0 g" or "/Helv 12 Tf 0 0 0 rg"
    da = Map.get(widget, "/DA", @default_da)
    {font_name, font_size, color_prefix, color_op} = parse_da(da)

    # Resolve font reference from AcroForm /DR /Font
    font_resources = resolve_font_resources(font_name, acroform_fonts)

    effective_size = if font_size > 0, do: font_size, else: 12.0

    # Escape the value for a PDF string literal
    escaped = escape_pdf_string(value)

    # Build content stream
    # The appearance is a Form XObject with BBox matching the widget rect.
    # Text is positioned at the bottom-left with a small margin.
    tx = @margin
    ty = @margin

    content_parts = [
      "q\n",
      "#{color_prefix} #{color_op}\n",
      "BT\n",
      "/#{font_name} #{format_float(effective_size)} Tf\n",
      "1 0 0 1 #{format_float(tx)} #{format_float(ty)} Tm\n",
      "(#{escaped}) Tj\n",
      "ET\n",
      "Q\n"
    ]

    data = IO.iodata_to_binary(content_parts)

    # Build the XObject Form dictionary
    stream_dict = %{
      "/Type" => {:name, "XObject"},
      "/Subtype" => {:name, "Form"},
      "/BBox" => [0.0, 0.0, width, height]
    }

    stream_dict =
      if font_resources != %{} do
        Map.put(stream_dict, "/Resources", %{"/Font" => font_resources})
      else
        stream_dict
      end

    # Allocate a fresh object ID for the appearance stream
    {:ok, next_id} = Pdf.allocate_object_id(doc)
    stream_id = {next_id, 0}

    :ok = Pdf.set_object(doc, stream_id, {:stream, stream_dict, data})

    # Update the widget's /AP to point at the new appearance stream
    existing_ap = Map.get(widget, "/AP", %{})
    updated_ap = Map.put(existing_ap, "/N", {:ref, next_id, 0})
    updated_widget = Map.put(widget, "/AP", updated_ap)

    Pdf.set_object(doc, widget_id, updated_widget)
  end

  # ── /DA parsing ─────────────────────────────────────────────────────────────

  @doc false
  # Parse a PDF default-appearance string.
  #
  # Returns `{font_name, font_size, color_prefix, color_op}`.
  #
  #   parse_da("/Helv 12 Tf 0 g")           -> {"Helv", 12.0, "0", "g"}
  #   parse_da("/Helv 12 Tf 0 0 0 rg")      -> {"Helv", 12.0, "0 0 0", "rg"}
  #   parse_da("/F1 10 Tf 0 0 0 rg")        -> {"F1", 10.0, "0 0 0", "rg"}
  #   parse_da("")                           -> {"Helv", 12.0, "0", "g"}
  def parse_da(da) when is_binary(da) do
    tokens = String.split(da)

    case find_tf(tokens) do
      {font_idx, size_idx} ->
        font_name = tokens |> Enum.at(font_idx) |> String.trim_leading("/")

        size =
          case Float.parse(Enum.at(tokens, size_idx) || "12") do
            {f, _} -> f
            :error -> 12.0
          end

        # Everything after Tf is colour specification
        color_tokens = tokens |> Enum.drop(size_idx + 2)

        case color_tokens do
          [a, op | _] when op in ["g", "G"] ->
            {font_name, size, a, op}

          [a, b, c, op | _] when op in ["rg", "RG", "k", "K"] ->
            {font_name, size, "#{a} #{b} #{c}", op}

          [a, b, c, d, op | _] when op in ["k", "K"] ->
            {font_name, size, "#{a} #{b} #{c} #{d}", op}

          _ ->
            {font_name, size, "0", "g"}
        end

      nil ->
        {"Helv", 12.0, "0", "g"}
    end
  end

  defp find_tf(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.find_value(fn
      {token, idx} -> if token == "Tf" and idx >= 2, do: {idx - 2, idx - 1}
      _ -> nil
    end)
  end

  # ── Font resource resolution ────────────────────────────────────────────────

  defp resolve_font_resources(font_name, acroform_fonts) do
    key = "/#{font_name}"

    case Map.get(acroform_fonts, key) do
      {:ref, _num, _gen} = ref ->
        %{key => ref}

      _ ->
        # Font not in /DR — pass through as a standard font name.
        # Common /DR-less forms use /Helv -> Helvetica, /TiRo -> Times-Roman,
        # /CoBo -> Courier. Any standard PDF font renders even without an
        # explicit resource entry.
        %{}
    end
  end

  # ── PDF string escaping ─────────────────────────────────────────────────────

  @doc false
  def escape_pdf_string(s) when is_binary(s) do
    s
    |> :binary.replace("\\", "\\\\", [:global])
    |> :binary.replace("(", "\\(", [:global])
    |> :binary.replace(")", "\\)", [:global])
    |> :binary.replace("\n", "\\n", [:global])
    |> :binary.replace("\r", "\\r", [:global])
    |> :binary.replace("\t", "\\t", [:global])
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp ref_from_dict(dict, key) do
    case dict do
      %{^key => {:ref, num, gen}} -> {:ok, {num, gen}}
      _ -> {:error, :not_found}
    end
  end

  defp ref_to_id({:ref, num, gen}), do: {num, gen}
  defp ref_to_id({num, gen}), do: {num, gen}

  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_float(n), do: n

  defp format_float(f) when is_float(f) do
    s = :erlang.float_to_binary(f, [:compact, decimals: 2])
    if String.contains?(s, "."), do: s, else: s <> ".0"
  end
end
