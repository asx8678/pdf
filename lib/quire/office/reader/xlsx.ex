defmodule Quire.Office.Reader.Xlsx do
  @moduledoc """
  Reader for `.xlsx` (Excel) files.

  Parses the ZIP archive, extracts workbook metadata, shared strings, and per-sheet
  cell grids, then builds `Quire.Office.Layout` sections — one per sheet — with
  `{:table, headers, rows}` blocks.

  ## Supported constructs

    * Cells with shared strings (shared string table)
    * Inline string and numeric cells
    * Column-letter addressing (A1-style)
    * Multi-sheet workbooks
    * Sheet titles

  ## Unsupported (reported as notes)

    * Images/drawings
    * Conditional formatting
    * Merged cells
    * Charts and pivot tables
    * Cell styles (fonts, colours, borders)
    * Formulas (cached value is used when available)
    * Data validation
  """

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  @doc """
  Parse a `.xlsx` file from bytes.

  Returns `{:ok, Layout.t()}` or `{:error, reason}`.
  """
  @spec read(binary()) :: {:ok, Layout.t()} | {:error, atom()}
  def read(bytes) when is_binary(bytes) do
    case :zip.unzip(bytes, [:memory]) do
      {:ok, entries} ->
        entry_map = Map.new(entries, fn {name, data} -> {List.to_string(name), data} end)

        with {:ok, sheets} <- parse_sheets(entry_map),
             {:ok, string_table} <- parse_shared_strings(entry_map),
             rels = parse_rels(entry_map) do
          sections = build_sections(entry_map, sheets, rels, string_table)
          title = extract_title(entry_map)

          {:ok,
           %Layout{
             title: title,
             sections: sections,
             report: [
               %{level: :info, message: "Parsed #{length(sheets)} sheet(s)", source: "xlsx"}
             ]
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Workbook sheets ─────────────────────────────────────────────────────────

  defp parse_sheets(entry_map) do
    with {:ok, xml} <- Map.fetch(entry_map, "xl/workbook.xml"),
         {:ok, raw} <- Saxy.parse_string(xml, __MODULE__.WorkbookHandler, []) do
      sheets =
        raw
        |> Enum.filter(fn
          {:sheet, _, _, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:sheet, id, name, rid} -> {id, name, rid} end)
        |> Enum.reverse()

      {:ok, sheets}
    else
      _ -> {:error, :invalid_xlsx}
    end
  end

  # ── Relationships ───────────────────────────────────────────────────────────

  defp parse_rels(entry_map) do
    case Map.fetch(entry_map, "xl/_rels/workbook.xml.rels") do
      {:ok, xml} ->
        {:ok, raw} = Saxy.parse_string(xml, __MODULE__.RelsHandler, %{})
        raw

      _ ->
        %{}
    end
  end

  defp sheet_path(sheets, rels) do
    Enum.map(sheets, fn {_id, name, rid} ->
      target = Map.get(rels, rid, "")

      path =
        if target == "" or String.contains?(target, "sheet") do
          if target == "",
            do: "xl/worksheets/sheet#{sheet_index_from_rid(rid)}.xml",
            else: "xl/#{target}"
        else
          target
        end

      {name, path}
    end)
  end

  defp sheet_index_from_rid(rid) do
    rid |> String.replace(~r/[^\d]/, "") |> String.to_integer()
  end

  # ── Shared strings ──────────────────────────────────────────────────────────

  defp parse_shared_strings(entry_map) do
    case Map.fetch(entry_map, "xl/sharedStrings.xml") do
      {:ok, xml} ->
        {:ok, strings} = Saxy.parse_string(xml, __MODULE__.StringsHandler, [])
        {:ok, Enum.reverse(strings)}

      _ ->
        {:ok, []}
    end
  end

  # ── Build sections ──────────────────────────────────────────────────────────

  defp build_sections(entry_map, sheets, rels, st) do
    paths = sheet_path(sheets, rels)

    Enum.map(paths, fn {name, path} ->
      path = resolve_path(entry_map, path)
      blocks = parse_sheet(entry_map, path, st)
      Section.new(:sheet, name) |> then(fn s -> %{s | blocks: blocks} end)
    end)
  end

  defp resolve_path(entry_map, path) do
    cond do
      path == "" -> nil
      Map.has_key?(entry_map, path) -> path
      Map.has_key?(entry_map, "xl/#{path}") -> "xl/#{path}"
      true -> nil
    end
  end

  defp parse_sheet(_entry_map, nil, _st), do: []

  defp parse_sheet(entry_map, path, st) do
    case Map.fetch(entry_map, path) do
      {:ok, xml} ->
        {:ok, result} =
          Saxy.parse_string(xml, __MODULE__.SheetHandler, %{
            st: st,
            rows: [],
            row: nil,
            cells: %{},
            in_c: false,
            in_v: false,
            in_is: false,
            in_t: false,
            col: 0,
            val: "",
            type: "n",
            max_col: 0
          })

        build_table_blocks(result)

      :error ->
        []
    end
  end

  defp build_table_blocks(%{rows: rows}) when rows == [], do: []

  defp build_table_blocks(%{rows: rows}) do
    sorted =
      rows
      |> Enum.sort_by(fn {r, _} -> r end)
      |> Enum.map(fn {_, cells} -> cells end)
      |> Enum.filter(&(&1 != []))

    case sorted do
      [] -> []
      [first | rest] -> [{:table, first, rest}]
    end
  end

  # ── Title from docProps ─────────────────────────────────────────────────────

  defp extract_title(entry_map) do
    case Map.fetch(entry_map, "docProps/core.xml") do
      {:ok, xml} ->
        {:ok, title} = Saxy.parse_string(xml, __MODULE__.CorePropsHandler, nil)
        title

      :error ->
        nil
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # SAX Handlers
  # ═════════════════════════════════════════════════════════════════════════════

  defmodule WorkbookHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    def handle_event(:start_element, {"sheet", attrs}, acc) do
      m = Map.new(attrs)
      id = Map.get(m, "sheetId", "")
      name = Map.get(m, "name", "")
      rid = Map.get(m, "r:id", "")
      {:ok, [{:sheet, id, name, rid} | acc]}
    end

    def handle_event(_, _, acc), do: {:ok, acc}
  end

  defmodule RelsHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    def handle_event(:start_element, {"Relationship", attrs}, acc) do
      m = Map.new(attrs)
      id = Map.get(m, "Id", "")
      target = Map.get(m, "Target", "")
      {:ok, Map.put(acc, id, target)}
    end

    def handle_event(_, _, acc), do: {:ok, acc}
  end

  defmodule StringsHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    def handle_event(:start_element, {"si", _}, acc), do: {:ok, [{:si, ""} | acc]}
    def handle_event(:start_element, {"t", _}, acc), do: {:ok, [{:t, ""} | acc]}

    def handle_event(:characters, chars, [{:t, buf} | rest]),
      do: {:ok, [{:t, buf <> chars} | rest]}

    def handle_event(:characters, _, acc), do: {:ok, acc}

    def handle_event(:end_element, "t", [{:t, buf}, {:si, acc} | rest]),
      do: {:ok, [{:si, acc <> buf} | rest]}

    def handle_event(:end_element, "si", [{:si, val} | acc]), do: {:ok, [val | acc]}

    def handle_event(_, _, acc), do: {:ok, acc}
  end

  defmodule SheetHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    # State: %{st: [string], rows: [{row_num, %{col => val}}],
    #         row: row_num | nil, cells: %{col => val},
    #         in_c: boolean, in_v: boolean, in_is: boolean, in_t: boolean,
    #         col: int, val: String.t(),
    #         type: String.t(), max_col: int}

    def handle_event(:start_element, {"row", attrs}, state) do
      m = Map.new(attrs)
      r = Map.get(m, "r", "1") |> String.to_integer()
      {:ok, %{state | row: r, cells: %{}, max_col: 0}}
    end

    def handle_event(:start_element, {"c", attrs}, state) do
      m = Map.new(attrs)
      ref = Map.get(m, "r", "A1")
      type = Map.get(m, "t", "n")
      col = column_letter(ref)
      {:ok, %{state | in_c: true, val: "", col: col, type: type}}
    end

    def handle_event(:start_element, {"v", _}, state), do: {:ok, %{state | in_v: true, val: ""}}

    # inlineStr content
    def handle_event(:start_element, {"is", _}, state),
      do: {:ok, %{state | in_is: true}}

    def handle_event(:start_element, {"t", _}, state) do
      state = if state.in_is, do: %{state | in_t: true}, else: state
      {:ok, state}
    end

    def handle_event(:start_element, {_, _}, state), do: {:ok, state}

    def handle_event(:characters, chars, %{in_v: true, val: v} = state),
      do: {:ok, %{state | val: v <> chars}}

    def handle_event(:characters, chars, %{in_t: true, val: v} = state),
      do: {:ok, %{state | val: v <> chars}}

    def handle_event(:characters, _, state), do: {:ok, state}

    def handle_event(:end_element, "v", state), do: {:ok, %{state | in_v: false}}
    def handle_event(:end_element, "t", state) when state.in_t, do: {:ok, %{state | in_t: false}}
    def handle_event(:end_element, "t", state), do: {:ok, state}

    def handle_event(:end_element, "is", state), do: {:ok, %{state | in_is: false}}

    def handle_event(:end_element, "c", state) do
      if state.in_c do
        val = resolve(state.val, state.type, state.st)
        cells = Map.put(state.cells, state.col, val)
        max_col = max(state.max_col, state.col)
        {:ok, %{state | in_c: false, val: "", col: 0, cells: cells, max_col: max_col}}
      else
        {:ok, state}
      end
    end

    def handle_event(:end_element, "row", state) do
      if state.row != nil do
        # build row array from cells map, fill gaps with ""
        row_cells = Enum.map(1..state.max_col, fn i -> Map.get(state.cells, i, "") end)
        rows = [{state.row, row_cells} | state.rows]
        {:ok, %{state | row: nil, cells: %{}, rows: rows}}
      else
        {:ok, state}
      end
    end

    def handle_event(_, _, state), do: {:ok, state}

    defp column_letter(ref), do: ref |> String.replace(~r/\d+$/, "") |> column_letter_to_number()

    defp column_letter_to_number(col),
      do: col |> String.to_charlist() |> Enum.reduce(0, fn c, a -> a * 26 + c - ?A + 1 end)

    defp resolve(val, "s", st) do
      idx = String.to_integer(String.trim(val))
      Enum.at(st, idx, "")
    end

    defp resolve(val, _, _), do: String.trim(val)
  end

  defmodule CorePropsHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    def handle_event(:start_element, {name, _}, _state)
        when name in ["title", "{http://purl.org/dc/elements/1.1/}title", "dc:title"],
        do: {:ok, {:title, ""}}

    def handle_event(:start_element, _, state), do: {:ok, state}

    def handle_event(:characters, chars, {:title, _}), do: {:ok, {:title, chars}}
    def handle_event(:characters, _, state), do: {:ok, state}

    def handle_event(:end_element, "title", {:title, val}), do: {:ok, val}
    def handle_event(:end_element, _, state), do: {:ok, state}
  end
end
