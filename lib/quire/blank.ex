defmodule Quire.Blank do
  @moduledoc ~S"""
  Blank-document and template creation (§9.2, T-085).

  Server-side creation via the PDFium NIF (`ExPdfium.new/0` + `add_page/2`),
  so the result is a real, openable PDF with the chosen page size.

  ## Sizes

  `:a4` 595×842 · `:letter` 612×792 · `:legal` 612×1008 (points).
  """

  @sizes %{
    a4: {595.0, 842.0},
    letter: {612.0, 792.0},
    legal: {612.0, 1008.0}
  }

  @templates [
    %{id: "letter", name: "Letter", desc: "Plain letterhead with a title and a rule"},
    %{id: "cover", name: "Cover page", desc: "Centered title block for reports"},
    %{id: "grid", name: "Grid paper", desc: "Light grid lines for notes and drafts"},
    %{id: "notes", name: "Meeting notes", desc: "Heading plus ruled lines for notes"}
  ]

  @doc "Returns the list of available templates."
  @spec templates() :: [map()]
  def templates, do: @templates

  @doc "Returns the page dimensions for a size, honouring orientation."
  @spec page_size(atom(), :portrait | :landscape) :: {float(), float()}
  def page_size(size, orientation) do
    {w, h} = Map.fetch!(@sizes, size)

    case orientation do
      :landscape -> {h, w}
      _ -> {w, h}
    end
  end

  @doc """
  Creates a blank single-page PDF.

  Returns `{:ok, pdf_bytes}` or `{:error, reason}`.
  """
  @spec create(atom(), :portrait | :landscape) :: {:ok, binary()} | {:error, term()}
  def create(size, orientation \\ :portrait) do
    {w, h} = page_size(size, orientation)

    with {:ok, doc} <- ExPdfium.new(),
         {:ok, doc} <- ExPdfium.add_page(doc, {w, h}),
         {:ok, bytes} <- ExPdfium.save_to_bytes(doc) do
      {:ok, bytes}
    end
  end

  @doc """
  Creates a template PDF.

  Returns `{:ok, pdf_bytes}` or `{:error, reason}`.
  """
  @spec render_template(String.t() | atom(), atom(), :portrait | :landscape) ::
          {:ok, binary()} | {:error, term()}
  def render_template(template_id, size \\ :a4, orientation \\ :portrait) do
    {w, h} = page_size(size, orientation)

    with {:ok, doc} <- ExPdfium.new(),
         {:ok, doc} <- ExPdfium.add_page(doc, {w, h}) do
      doc =
        case template_id do
          "letter" -> draw_letter(doc, w, h)
          "cover" -> draw_cover(doc, w, h)
          "grid" -> draw_grid(doc, w, h)
          "notes" -> draw_notes(doc, w, h)
          _ -> doc
        end

      ExPdfium.save_to_bytes(doc)
    end
  end

  # ── Template drawing ───────────────────────────────────────────────────

  defp draw_letter(doc, w, h) do
    with {:ok, doc} <-
           ExPdfium.draw_text(doc, 0, {72.0, h - 72.0}, "Title", font: :helvetica, size: 28),
         {:ok, doc} <- ExPdfium.draw_line(doc, 0, {72.0, h - 100.0}, {w - 72.0, h - 100.0}),
         {:ok, doc} <-
           ExPdfium.draw_text(doc, 0, {72.0, h - 130.0}, "Dear reader,",
             font: :helvetica,
             size: 12
           ) do
      doc
    else
      _ -> doc
    end
  end

  defp draw_cover(doc, w, h) do
    with {:ok, doc} <-
           ExPdfium.draw_rectangle(
             doc,
             0,
             %{left: 50.0, bottom: 50.0, right: w - 100.0, top: h - 100.0},
             fill: {51, 102, 204}
           ),
         {:ok, doc} <-
           ExPdfium.draw_text(doc, 0, {w / 2 - 150.0, h / 2}, "Report title",
             font: :helvetica,
             size: 32
           ) do
      doc
    else
      _ -> doc
    end
  end

  defp draw_grid(doc, w, h) do
    step = 40.0

    vertical =
      Enum.reduce(0..trunc(w / step), doc, fn i, acc ->
        x = i * step

        case ExPdfium.draw_line(acc, 0, {x, 0.0}, {x, h}, color: {217, 217, 217}) do
          {:ok, d} -> d
          _ -> acc
        end
      end)

    Enum.reduce(0..trunc(h / step), vertical, fn j, acc ->
      y = j * step

      case ExPdfium.draw_line(acc, 0, {0.0, y}, {w, y}, color: {217, 217, 217}) do
        {:ok, d} -> d
        _ -> acc
      end
    end)
  end

  defp draw_notes(doc, w, h) do
    with {:ok, doc} <-
           ExPdfium.draw_text(doc, 0, {72.0, h - 72.0}, "Meeting notes",
             font: :helvetica,
             size: 24
           ) do
      Enum.reduce(1..5, doc, fn i, acc ->
        y = h - 120.0 - i * 48.0

        case ExPdfium.draw_line(acc, 0, {72.0, y}, {w - 72.0, y}, color: {179, 179, 179}) do
          {:ok, d} -> d
          _ -> acc
        end
      end)
    else
      _ -> doc
    end
  end
end
