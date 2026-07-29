defmodule Quire.Office.Reader.Ods do
  @moduledoc """
  Reader for `.ods` (OpenDocument Spreadsheet) files.

  Parses the ZIP archive, extracts `content.xml`, parses `<table:table>` elements
  as sheets with `<table:table-row>` and `<table:table-cell>` elements, then builds
  `Quire.Office.Layout` sections — one per sheet — with `{:table, headers, rows}` blocks.

  ## Supported constructs

    * Multi-sheet spreadsheets
    * Sheet titles (from `table:name`)
    * String and numeric cell values
    * `table:number-columns-repeated` for repeated cells
    * Namespace-qualified and prefixed element names
    * Multi-paragraph cell text (concatenated with newlines)

  ## Unsupported (reported as notes)

    * Formulas
    * Cell styles (fonts, colours, borders)
    * Merged cells (`table:number-columns-spanned`, `table:number-rows-spanned`)
    * Covered cells (`table:covered-table-cell`)
    * Images
    * Data validation
  """

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  @doc """
  Parse an `.ods` file from bytes.

  Returns `{:ok, Layout.t()}` or `{:error, reason}`.
  """
  @spec read(binary()) :: {:ok, Layout.t()} | {:error, atom()}
  def read(bytes) when is_binary(bytes) do
    case :zip.unzip(bytes, [:memory]) do
      {:ok, entries} ->
        entry_map = Map.new(entries, fn {name, data} -> {List.to_string(name), data} end)

        case parse_content(entry_map) do
          {:ok, sections} ->
            title = extract_title(entry_map)

            {:ok,
             %Layout{
               title: title,
               sections: sections,
               report: [
                 %{level: :info, message: "Parsed #{length(sections)} sheet(s)", source: "ods"}
               ]
             }}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Content parsing ─────────────────────────────────────────────────────────

  defp parse_content(entry_map) do
    case Map.fetch(entry_map, "content.xml") do
      {:ok, xml} ->
        case Saxy.parse_string(xml, __MODULE__.ContentHandler, initial_state()) do
          {:ok, state} ->
            {:ok, finalize_sections(state)}

          {:error, _reason} ->
            {:error, :invalid_ods}
        end

      :error ->
        {:error, :invalid_ods}
    end
  end

  defp initial_state do
    %{
      sections: [],
      current_sheet: nil,
      rows: [],
      current_row: [],
      in_cell: false,
      cell_text: "",
      cell_type: "string",
      cell_repeat: 1,
      column_count: 0
    }
  end

  defp finalize_sections(%{sections: sections, current_sheet: nil, rows: []}) do
    Enum.reverse(sections)
  end

  defp finalize_sections(%{
         sections: sections,
         current_sheet: sheet,
         rows: rows,
         column_count: col_count
       }) do
    section = build_section(sheet, rows, col_count)
    Enum.reverse([section | sections])
  end

  defp build_section(sheet_name, rows, _col_count) do
    sorted =
      rows
      |> Enum.reverse()
      |> Enum.filter(&(&1 != []))

    blocks =
      case sorted do
        [] -> []
        [first | rest] -> [{:table, first, rest}]
      end

    Section.new(:sheet, sheet_name) |> then(fn s -> %{s | blocks: blocks} end)
  end

  # ── Title from meta.xml ─────────────────────────────────────────────────────

  defp extract_title(entry_map) do
    case Map.fetch(entry_map, "meta.xml") do
      {:ok, xml} ->
        case Saxy.parse_string(xml, __MODULE__.MetaHandler, nil) do
          {:ok, title} when is_binary(title) -> title
          _ -> nil
        end

      :error ->
        nil
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # ContentHandler — parses content.xml for table:table, table:table-row,
  # table:table-cell, and text:p elements
  # ═════════════════════════════════════════════════════════════════════════════

  defmodule ContentHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    alias Quire.Office.Layout.Section

    @doc false
    def handle_event(:start_element, {name, attrs}, state) do
      lname = local_name(name)

      cond do
        # <table:table> — start a new sheet
        lname == "table" ->
          m = Map.new(attrs)

          sheet_name =
            Map.get(m, "table:name") ||
              Map.get(m, "{urn:oasis:names:tc:opendocument:xmlns:table:1.0}name", "Sheet")

          {:ok, %{state | current_sheet: sheet_name, rows: [], column_count: 0}}

        # <table:table-row> — start a new row
        lname == "table-row" ->
          {:ok, %{state | current_row: []}}

        # <table:table-cell> or <table:covered-table-cell>
        lname == "table-cell" or lname == "covered-table-cell" ->
          m = Map.new(attrs)

          val_type =
            Map.get(m, "office:value-type") ||
              Map.get(m, "{urn:oasis:names:tc:opendocument:xmlns:office:1.0}value-type", "string")

          repeat_str =
            Map.get(m, "table:number-columns-repeated") ||
              Map.get(
                m,
                "{urn:oasis:names:tc:opendocument:xmlns:table:1.0}number-columns-repeated",
                "1"
              )

          repeat = String.to_integer(repeat_str)
          {:ok, %{state | in_cell: true, cell_text: "", cell_type: val_type, cell_repeat: repeat}}

        # <text:p> — start or continue cell text
        lname == "p" ->
          cell_text =
            if state.in_cell and state.cell_text != "" do
              state.cell_text <> "\n"
            else
              state.cell_text
            end

          {:ok, %{state | cell_text: cell_text}}

        true ->
          {:ok, state}
      end
    end

    @doc false
    def handle_event(:characters, chars, state) do
      if state.in_cell do
        {:ok, %{state | cell_text: state.cell_text <> chars}}
      else
        {:ok, state}
      end
    end

    @doc false
    def handle_event(:end_element, name, state) do
      lname = local_name(name)

      cond do
        # </table:table-cell> or </table:covered-table-cell> — push cell to row
        lname == "table-cell" or lname == "covered-table-cell" ->
          if state.in_cell do
            val = state.cell_text
            row = state.current_row ++ List.duplicate(val, state.cell_repeat)
            col_count = max(state.column_count, length(row))

            {:ok,
             %{
               state
               | in_cell: false,
                 cell_text: "",
                 cell_repeat: 1,
                 current_row: row,
                 column_count: col_count
             }}
          else
            {:ok, state}
          end

        # </table:table-row> — push row to sheet rows
        lname == "table-row" ->
          row = state.current_row
          col_count = state.column_count
          padded = row ++ List.duplicate("", max(0, col_count - length(row)))
          {:ok, %{state | rows: [padded | state.rows], current_row: []}}

        # </table:table> — finalize current sheet into a section
        lname == "table" ->
          section = build_section(state.current_sheet, state.rows, state.column_count)

          {:ok,
           %{
             state
             | sections: [section | state.sections],
               current_sheet: nil,
               rows: [],
               column_count: 0
           }}

        true ->
          {:ok, state}
      end
    end

    def handle_event(_, _, state), do: {:ok, state}

    defp local_name(name) do
      if String.contains?(name, "}") do
        String.split(name, "}") |> List.last()
      else
        name |> String.split(":") |> List.last()
      end
    end

    defp build_section(sheet_name, rows, _col_count) do
      sorted =
        rows
        |> Enum.reverse()
        |> Enum.filter(&(&1 != []))

      blocks =
        case sorted do
          [] -> []
          [first | rest] -> [{:table, first, rest}]
        end

      Section.new(:sheet, sheet_name) |> then(fn s -> %{s | blocks: blocks} end)
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # MetaHandler — extracts dc:title from meta.xml
  # ═════════════════════════════════════════════════════════════════════════════

  defmodule MetaHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    @doc false
    def handle_event(:start_element, {name, _}, _state) do
      if String.ends_with?(name, "title") do
        {:ok, {:title, ""}}
      else
        {:ok, nil}
      end
    end

    @doc false
    def handle_event(:characters, chars, {:title, _}), do: {:ok, {:title, chars}}

    @doc false
    def handle_event(:characters, _, state), do: {:ok, state}

    @doc false
    def handle_event(:end_element, name, {:title, val}) do
      if String.ends_with?(name, "title") do
        {:ok, val}
      else
        {:ok, {:title, val}}
      end
    end

    @doc false
    def handle_event(:end_element, _, state), do: {:ok, state}
  end
end
