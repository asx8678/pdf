defmodule Quire.Editing.Ops.MarkPageNumber do
  @moduledoc """
  Validates and applies a `mark.page_number` operation (plan3.md §9.5,
  T-095).

  The first stamping op; it establishes the shared mechanism that T-096
  (watermark / header-footer) and T-097 (Bates) reuse through
  `Quire.Editing.Mark`. Compose generates the stamp text
  (`Quire.Editing.Mark.PageNumber`); PDFium page objects apply it via
  `ExPdfium.draw_text/6`.

  ## Expected op_data fields

    * `"ref"` — `Quire.Storage.Ref` pointing at the current revision bytes
      (or `"pdf_bytes"` for a raw-bytes call — the LiveView flow injects
      the current revision)
    * `"anchor"` — one of `Quire.Editing.Mark.anchors/0`
      (default `"bottom_center"`)
    * `"format"` — one of `Quire.Editing.Mark.PageNumber.formats/0`
      (default `"1"`)
    * `"start_at"` — number the first stamped page at this value
      (default 1)
    * `"pages"` — page-range selector map (see
      `Quire.Editing.Mark.PageRange`; default all pages)
    * `"font"` / `"font_size"` / `"color"` — stamp typography
    * `"margin"` — distance from the page edge in points (default 36.0)

  ## Returns

    * `{:ok, %{pdf_bytes: new_bytes, ref: new_ref, pages: [...]}}` when
      given a `ref` — the stamped document is stored and a new ref
      returned, ready for `Quire.Editing.flush/3`.
    * `{:ok, %{pdf_bytes: new_bytes, pages: [...]}}` when given
      `"pdf_bytes"` directly.
    * `{:error, reason}` — validation or stamping failure.

  Every returned payload carries `"mark"` (the validated mark spec),
  `"pages"` (the `{page_index, text}` pairs stamped, recorded in
  `text_edits` as app-applied marks) and `"id"` (stable mark id, so undo
  via `mark.remove` can target it).
  """

  alias Quire.Editing.Mark
  alias Quire.Editing.Mark.PageNumber
  alias Quire.Editing.Mark.Placement
  alias Quire.Storage.Ref

  @doc """
  Validates and applies the page-number stamping operation.

  See the module docs for accepted fields and return shapes.
  """
  def apply(op_data, _context) do
    with {:ok, source} <- source_bytes(op_data),
         {:ok, mark} <- Mark.validate_options(op_data),
         {:ok, format} <- validate_format(op_data),
         {:ok, geometries} <- page_geometries(source),
         {:ok, texts} <- build_texts(geometries, mark, format),
         {:ok, bytes} <- stamp(source, geometries, texts, mark, format) do
      result = %{
        "mark" => Map.put(mark, "format", format),
        "pages" => texts,
        "id" => mark_id(op_data)
      }

      case op_data[:ref] || op_data["ref"] do
        %Ref{} = ref ->
          with {:ok, new_ref} <-
                 Quire.Storage.put(bytes, name: ref.name || "stamped.pdf") do
            {:ok, Map.merge(result, %{"ref" => new_ref, "pdf_bytes" => bytes})}
          end

        _ ->
          {:ok, Map.put(result, "pdf_bytes", bytes)}
      end
    end
  end

  @doc """
  Computes the inverse of `mark.page_number`: the stamped text is part of
  the page content, so undo reverts to the pre-stamp revision.

  When the apply-time revision id is known (`context[:base_revision_id]`)
  it is used; otherwise the caller (EditSession) restores the previous
  persisted revision by id on its own.
  """
  def invert(_op_data, context) do
    {:ok, {:restore_revision, context[:base_revision_id]}}
  end

  @doc false
  # Public for reuse by T-096/T-097: builds the `{page_index, text}` list
  # for one mark spec. Exposed so sibling ops can stamp with the exact same
  # text-generation logic.
  def build_texts(geometries, mark, format) do
    page_count = length(geometries)

    texts =
      geometries
      |> Enum.with_index()
      |> Enum.flat_map(fn {_geom, page_index} ->
        case PageNumber.render(page_index, page_count,
               format: format,
               start_at: mark["start_at"],
               pages: mark["pages"]
             ) do
          nil -> []
          text -> [{page_index, text}]
        end
      end)

    {:ok, texts}
  end

  @doc false
  # Public for reuse: draws `texts` on the source bytes using the mark spec
  # and geometry, returning the stamped bytes.
  def stamp(source, geometries, texts, mark, _format) do
    Enum.reduce_while(texts, {:ok, source}, fn {page_index, text}, {:ok, bytes} ->
      geometry = Enum.at(geometries, page_index)

      rect =
        Placement.rect(mark["anchor"], mark["margin"], geometry,
          font_size: mark["font_size"],
          approx_width: approx_width(text, mark["font_size"])
        )

      case Mark.origin(rect, geometry) do
        {:ok, {x, y}} ->
          case Mark.draw(bytes, page_index, {x, y}, text,
                 font: mark["font"],
                 size: mark["font_size"],
                 color: Mark.draw_color(mark["color"])
               ) do
            {:ok, new_bytes} -> {:cont, {:ok, new_bytes}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp source_bytes(op_data) do
    cond do
      is_map(op_data["pdf_bytes"] || op_data[:pdf_bytes]) ->
        {:error, "mark.page_number requires pdf_bytes or ref"}

      is_binary(op_data["pdf_bytes"] || op_data[:pdf_bytes]) ->
        {:ok, op_data["pdf_bytes"] || op_data[:pdf_bytes]}

      match?(%Ref{}, op_data["ref"] || op_data[:ref]) ->
        ref = op_data["ref"] || op_data[:ref]

        case Quire.Storage.get(ref) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, reason} -> {:error, "mark.page_number could not read document: #{inspect(reason)}"}
        end

      true ->
        {:error, "mark.page_number requires pdf_bytes or ref"}
    end
  end

  defp validate_format(op_data) do
    format = op_data["format"] || op_data[:format] || "1"

    if format in PageNumber.formats() do
      {:ok, format}
    else
      {:error, "Unknown page-number format: #{format} (expected one of #{Enum.join(PageNumber.formats(), ", ")})"}
    end
  end

  defp page_geometries(pdf_bytes) do
    with {:ok, ref} <- Quire.Storage.put(pdf_bytes, name: "mark.page_number.pdf"),
         {:ok, geometries} <- Quire.Render.page_geometry(ref) do
      {:ok, geometries}
    else
      {:error, reason} -> {:error, "mark.page_number could not read page geometry: #{inspect(reason)}"}
    end
  end

  # Approximate the glyph width of a standard-14 font run: average advance
  # ≈ 0.5 em for Helvetica/Times, so width ≈ chars × size × 0.5 + size.
  # This keeps centre/right anchors on-target without font metrics; callers
  # that need exact placement can pass :approx_width through the mark spec.
  defp approx_width(text, font_size) do
    (String.length(text) * font_size * 0.5 + font_size) * 1.0
  end

  defp mark_id(op_data) do
    case op_data["id"] || op_data[:id] do
      id when is_binary(id) and id != "" -> id
      _ -> Ecto.UUID.generate()
    end
  end
end
