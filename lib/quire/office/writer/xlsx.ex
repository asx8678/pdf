defmodule Quire.Office.Writer.Xlsx do
  @moduledoc ~S"""
  Renders a `Quire.Office.Layout.t()` to an XLSX (OOXML) binary using elixlsx.

  Best for text-based PDFs. Formatting fidelity is best-effort.

  Each section of the layout becomes a sheet in the workbook. Blocks within
  a section are mapped to rows:

    * `{:paragraph, text}` → a single row in column A
    * `{:heading, text, level}` → a row with bold text in column A
    * `{:table, headers, rows}` → header row in column A, data rows below
    * `{:list, items, ordered}` → one row per item, with numbering indicator
    * `{:image, _, _, _}` → **skipped** (XLSX does not support inline images
      in cells with elixlsx)

  Images are silently dropped; elixlsx does not support embedding images
  in cells.
  """

  @behaviour Quire.Office.Writer

  alias Elixlsx.Sheet
  alias Elixlsx.Workbook
  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  # ── Behaviour callbacks ─────────────────────────────────────────────────

  @doc """
  Write layout to XLSX binary.

  ## Examples

      {:ok, xlsx_binary} = Quire.Office.Writer.Xlsx.write(layout, :xlsx, [])
  """
  @spec write(Layout.t(), :xlsx, keyword()) :: {:ok, binary()}
  def write(layout, format, _opts \\ [])

  def write(%Layout{} = layout, :xlsx, _opts) do
    sheets =
      layout.sections
      |> Enum.with_index(1)
      |> Enum.map(fn {section, idx} -> section_to_sheet(section, idx) end)

    workbook = %Workbook{sheets: sheets}

    with {:ok, {_name, binary}} <- Elixlsx.write_to_memory(workbook, "document.xlsx") do
      {:ok, binary}
    end
  end

  def write(%Layout{}, format, _opts) do
    {:error, "Unsupported format: #{inspect(format)}"}
  end

  @spec supported_formats() :: [:xlsx]
  def supported_formats, do: [:xlsx]

  # ── Section to sheet ────────────────────────────────────────────────────

  defp section_to_sheet(%Section{type: _type, title: title, blocks: blocks}, idx) do
    sheet_name = sheet_title(title, idx)
    rows = Enum.flat_map(blocks, &block_to_rows/1)
    %Sheet{name: sheet_name, rows: rows}
  end

  defp sheet_title(nil, idx), do: "Sheet #{idx}"

  defp sheet_title(title, idx) do
    title
    |> String.slice(0, 31)
    |> String.replace(~r/[:\/?*\[\]]/, " ")
    |> String.trim()
    |> then(fn s -> if s == "", do: "Sheet #{idx}", else: s end)
  end

  # ── Block to rows ───────────────────────────────────────────────────────

  defp block_to_rows({:paragraph, text}) do
    [[text]]
  end

  defp block_to_rows({:heading, text, _level}) do
    [[[text, bold: true]]]
  end

  defp block_to_rows({:table, headers, rows}) do
    header_row =
      if headers != [] do
        [Enum.map(headers, fn h -> [h, bold: true] end)]
      else
        []
      end

    data_rows = Enum.map(rows, fn row -> row end)
    header_row ++ data_rows
  end

  defp block_to_rows({:list, items, _ordered}) do
    Enum.map(items, fn item -> [item] end)
  end

  # Images silently dropped — elixlsx does not support embedding
  defp block_to_rows({:image, _bytes, _alt, _ext}), do: []

  defp block_to_rows(_unknown), do: []
end
