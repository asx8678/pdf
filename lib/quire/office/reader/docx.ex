defmodule Quire.Office.Reader.Docx do
  @moduledoc """
  Reader for `.docx` (Word) files.

  Parses the ZIP archive, extracts content from `word/document.xml`,
  resolves styles from `word/styles.xml`, numbering from `word/numbering.xml`,
  and images from `word/media/`, then builds `Quire.Office.Layout` sections.

  ## Supported constructs

    * Paragraphs (`<w:p>` → `{:paragraph, text}`)
    * Headings (`<w:pStyle>` matching `Heading1`–`Heading6` → `{:heading, text, level}`)
    * Ordered and unordered lists (`<w:numPr>` → `{:list, items, ordered}`)
    * Tables (`<w:tbl>` → `{:table, headers, rows}`)
    * Images (`<w:drawing>` → `{:image, bytes, alt, ext}`)
    * Inline runs (`<w:r>` + `<w:t>` combined into paragraph text)
    * Hyperlinks — text only, link target ignored
    * Document title from `docProps/core.xml`

  ## Unsupported (reported as notes)

    * Text formatting (fonts, colours, bold/italic — each paragraph is plain text)
    * Merged cells, nested tables
    * Footnotes, endnotes, comments, tracked changes
    * Content controls, embedded objects, charts, diagrams
    * Headers, footers, text boxes, ActiveX controls
  """

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  @heading_regex ~r/^heading\s*(\d+)$/i

  # ── Public entry point ──────────────────────────────────────────────────────

  @doc """
  Parse a `.docx` file from bytes.

  Returns `{:ok, Layout.t()}` or `{:error, reason}`.
  """
  @spec read(binary()) :: {:ok, Layout.t()} | {:error, atom()}
  def read(bytes) when is_binary(bytes) do
    with {:ok, entries} <- :zip.unzip(bytes, [:memory]) do
      entry_map = Map.new(entries, fn {name, data} -> {List.to_string(name), data} end)

      with {:ok, doc_xml} <- Map.fetch(entry_map, "word/document.xml") do
        styles = parse_styles(entry_map)
        numbering = parse_numbering(entry_map)
        rels = parse_rels(entry_map)

        state = %{
          blocks: [],
          text_parts: [],
          current_style_id: nil,
          current_num_id: nil,
          in_body: 0,
          in_paragraph: 0,
          in_paragraph_properties: 0,
          in_run: 0,
          in_text: 0,
          in_hyperlink: 0,
          in_table: 0,
          in_row: 0,
          in_cell: 0,
          in_table_grid: 0,
          in_drawing: 0,
          in_doc_pr: 0,
          in_blip: 0,
          in_header_ref: 0,
          in_footer_ref: 0,
          cell_texts: [],
          row_cells: [],
          rows_accum: [],
          image_rid: nil,
          image_alt: nil,
          styles: styles,
          numbering: numbering,
          rels: rels,
          entry_map: entry_map,
          notes: []
        }

        case Saxy.parse_string(doc_xml, __MODULE__.DocumentHandler, state) do
          {:ok, state} ->
            state = do_finalize_paragraph(state)
            blocks = state.blocks |> group_lists()
            title = extract_title(entry_map)
            notes = Enum.reverse(state.notes)

            report = [
              %{level: :info, message: "Parsed 1 document", source: "docx"} | notes
            ]

            section = Section.new(:page, nil) |> then(fn s -> %{s | blocks: blocks} end)
            {:ok, %Layout{title: title, sections: [section], report: report}}

          {:error, _} ->
            {:error, :invalid_docx}
        end
      else
        _ -> {:error, :invalid_docx}
      end
    else
      {:error, _} -> {:error, :invalid_docx}
    end
  end

  # ── Helpers called from DocumentHandler (public for cross-module access) ────

  @doc false
  def finalize_paragraph(state) do
    do_finalize_paragraph(state)
  end

  @doc false
  def do_finalize_paragraph(state) do
    text = state.text_parts |> Enum.reverse() |> Enum.join("") |> String.trim()

    block =
      cond do
        state.current_num_id != nil and text != "" ->
          ordered = numbering_ordered?(state.numbering, state.current_num_id)
          {:list_item, text, ordered}

        state.current_style_id != nil and text != "" ->
          case heading_level(state.styles, state.current_style_id) do
            {:ok, level} -> {:heading, text, level}
            _ -> {:paragraph, text}
          end

        text != "" ->
          {:paragraph, text}

        true ->
          nil
      end

    state = %{state | text_parts: [], current_style_id: nil, current_num_id: nil}

    if block, do: %{state | blocks: [block | state.blocks]}, else: state
  end

  @doc false
  def match_ns(name, local) do
    name == local or
      name == "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}#{local}" or
      String.ends_with?(name, ":#{local}")
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp parse_styles(entry_map) do
    case Map.fetch(entry_map, "word/styles.xml") do
      {:ok, xml} ->
        {:ok, result} = Saxy.parse_string(xml, __MODULE__.StylesHandler, %{})
        result

      _ ->
        %{}
    end
  end

  defp parse_numbering(entry_map) do
    case Map.fetch(entry_map, "word/numbering.xml") do
      {:ok, xml} ->
        {:ok, result} =
          Saxy.parse_string(xml, __MODULE__.NumberingHandler, %{
            num_map: %{},
            abstract_levels: %{},
            current_num: nil,
            current_abs_id: nil,
            cur_abs_def: nil,
            in_abs: false,
            in_lvl: false,
            current_ilvl: nil,
            current_fmt: nil
          })

        result

      _ ->
        %{num_map: %{}, abstract_levels: %{}}
    end
  end

  defp parse_rels(entry_map) do
    case Map.fetch(entry_map, "word/_rels/document.xml.rels") do
      {:ok, xml} ->
        {:ok, result} = Saxy.parse_string(xml, __MODULE__.RelsHandler, %{})
        result

      _ ->
        %{}
    end
  end

  defp heading_level(styles, style_id) do
    name = Map.get(styles, String.downcase(style_id), "")

    case Regex.run(@heading_regex, String.slice(name, 0, 20)) do
      [_, lvl] ->
        level = String.to_integer(lvl)
        {:ok, min(max(level, 1), 6)}

      nil ->
        :error
    end
  end

  defp numbering_ordered?(numbering, num_id) do
    abs_id = Map.get(numbering.num_map, num_id)

    if abs_id do
      fmt = Map.get(numbering.abstract_levels, {abs_id, 0})
      fmt != "bullet"
    else
      false
    end
  end

  defp extract_title(entry_map) do
    case Map.fetch(entry_map, "docProps/core.xml") do
      {:ok, xml} ->
        {:ok, title} = Saxy.parse_string(xml, __MODULE__.CorePropsHandler, nil)
        title

      :error ->
        nil
    end
  end

  defp group_lists(blocks) do
    blocks
    |> Enum.reverse()
    |> do_group_lists([], [])
    |> Enum.reverse()
  end

  defp do_group_lists([], acc, list_acc) do
    if list_acc == [], do: acc, else: [finalize_list(list_acc) | acc]
  end

  defp do_group_lists([{:list_item, text, ordered} | rest], acc, list_acc) do
    do_group_lists(rest, acc, [{text, ordered} | list_acc])
  end

  defp do_group_lists([block | rest], acc, []) do
    do_group_lists(rest, [block | acc], [])
  end

  defp do_group_lists([block | rest], acc, list_acc) do
    do_group_lists(rest, [block, finalize_list(list_acc) | acc], [])
  end

  defp finalize_list(items) do
    {texts, ordered_flags} = Enum.unzip(Enum.reverse(items))
    ordered = Enum.any?(ordered_flags)
    {:list, texts, ordered}
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # DocumentHandler — parses word/document.xml
  # ═════════════════════════════════════════════════════════════════════════════

  defmodule DocumentHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    defp finalize_p(state), do: Quire.Office.Reader.Docx.finalize_paragraph(state)

    defp match_ns(n, l), do: Quire.Office.Reader.Docx.match_ns(n, l)

    defp extract_embed_rid(attrs) do
      Enum.find_value(attrs, fn
        {"r:embed", v} -> v
        {k, v} when is_binary(k) -> if String.ends_with?(k, "}embed"), do: v, else: nil
        _ -> nil
      end)
    end

    defp extract_img(state, rid, alt) do
      target = Map.get(state.rels, rid)

      if target == nil do
        {%{state | image_rid: nil, image_alt: nil}, nil}
      else
        path =
          if String.starts_with?(target, "media/"),
            do: "word/#{target}",
            else: target

        case Map.fetch(state.entry_map, path) do
          {:ok, bytes} ->
            ext = path |> String.split(".") |> List.last() |> String.downcase()
            {%{state | image_rid: nil, image_alt: nil}, {:image, bytes, alt || "image", ext}}

          _ ->
            {%{state | image_rid: nil, image_alt: nil}, nil}
        end
      end
    end

    # ── start_element ────────────────────────────────────────────────────────

    def handle_event(:start_element, {name, attrs}, state) do
      cond do
        match_ns(name, "body") ->
          {:ok, %{state | in_body: state.in_body + 1}}

        match_ns(name, "p") ->
          state = finalize_p(state)
          {:ok, %{state | in_paragraph: state.in_paragraph + 1}}

        match_ns(name, "pPr") ->
          {:ok, %{state | in_paragraph_properties: state.in_paragraph_properties + 1}}

        match_ns(name, "pStyle") ->
          am = Map.new(attrs)

          sid =
            Map.get(am, "w:val") ||
              Map.get(am, "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}val")

          {:ok, %{state | current_style_id: sid}}

        match_ns(name, "numPr") ->
          {:ok, state}

        match_ns(name, "numId") ->
          am = Map.new(attrs)

          ns =
            Map.get(am, "w:val") ||
              Map.get(am, "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}val")

          nid = if ns, do: String.to_integer(ns), else: nil
          {:ok, %{state | current_num_id: nid}}

        match_ns(name, "ilvl") ->
          {:ok, state}

        match_ns(name, "r") ->
          {:ok, %{state | in_run: state.in_run + 1}}

        match_ns(name, "t") ->
          {:ok, %{state | in_text: state.in_text + 1}}

        match_ns(name, "hyperlink") ->
          {:ok, %{state | in_hyperlink: state.in_hyperlink + 1}}

        match_ns(name, "tbl") ->
          {:ok, %{state | in_table: state.in_table + 1}}

        match_ns(name, "tr") ->
          {:ok, %{state | in_row: state.in_row + 1, row_cells: []}}

        match_ns(name, "tc") ->
          {:ok, %{state | in_cell: state.in_cell + 1, cell_texts: []}}

        match_ns(name, "tblGrid") ->
          {:ok, %{state | in_table_grid: state.in_table_grid + 1}}

        match_ns(name, "drawing") ->
          {:ok, %{state | in_drawing: state.in_drawing + 1}}

        match_ns(name, "docPr") ->
          attr_map = Map.new(attrs)
          alt = Map.get(attr_map, "descr") || Map.get(attr_map, "name", "image")
          {:ok, %{state | in_doc_pr: state.in_doc_pr + 1, image_alt: alt}}

        name == "pic:blip" or name == "a:blip" or String.ends_with?(name, "}blip") ->
          rid = extract_embed_rid(attrs)
          {:ok, %{state | image_rid: rid, in_blip: state.in_blip + 1}}

        match_ns(name, "headerReference") ->
          {:ok, %{state | in_header_ref: state.in_header_ref + 1}}

        match_ns(name, "footerReference") ->
          {:ok, %{state | in_footer_ref: state.in_footer_ref + 1}}

        match_ns(name, "sectPr") ->
          {:ok, state}

        true ->
          {:ok, state}
      end
    end

    # ── characters ──────────────────────────────────────────────────────────

    def handle_event(:characters, chars, state) do
      if state.in_text > 0 and state.in_run > 0 and state.in_paragraph > 0 do
        {:ok, %{state | text_parts: [chars | state.text_parts]}}
      else
        {:ok, state}
      end
    end

    # ── end_element ──────────────────────────────────────────────────────────

    def handle_event(:end_element, name, state) do
      cond do
        match_ns(name, "body") ->
          {:ok, %{state | in_body: max(0, state.in_body - 1)}}

        match_ns(name, "p") ->
          if state.in_cell > 0 do
            text =
              state.text_parts |> Enum.reverse() |> Enum.join("") |> String.trim()

            cell_texts =
              if text != "", do: [text | state.cell_texts], else: state.cell_texts

            {:ok,
             %{
               state
               | text_parts: [],
                 current_style_id: nil,
                 current_num_id: nil,
                 in_paragraph: max(0, state.in_paragraph - 1),
                 cell_texts: cell_texts
             }}
          else
            state = finalize_p(state)
            {:ok, %{state | in_paragraph: max(0, state.in_paragraph - 1)}}
          end

        match_ns(name, "pPr") ->
          {:ok, %{state | in_paragraph_properties: max(0, state.in_paragraph_properties - 1)}}

        match_ns(name, "r") ->
          {:ok, %{state | in_run: max(0, state.in_run - 1)}}

        match_ns(name, "t") ->
          {:ok, %{state | in_text: max(0, state.in_text - 1)}}

        match_ns(name, "hyperlink") ->
          {:ok, %{state | in_hyperlink: max(0, state.in_hyperlink - 1)}}

        match_ns(name, "tbl") ->
          rows = Enum.reverse(state.rows_accum)

          tb =
            case rows do
              [] -> nil
              [first | rest] -> {:table, first, rest}
            end

          blocks = if tb, do: [tb | state.blocks], else: state.blocks

          {:ok,
           %{
             state
             | in_table: max(0, state.in_table - 1),
               rows_accum: [],
               row_cells: [],
               blocks: blocks
           }}

        match_ns(name, "tr") ->
          cells = Enum.reverse(state.row_cells)

          {:ok,
           %{
             state
             | in_row: max(0, state.in_row - 1),
               rows_accum: [cells | state.rows_accum],
               row_cells: []
           }}

        match_ns(name, "tc") ->
          ct = state.cell_texts |> Enum.reverse() |> Enum.join(" ") |> String.trim()

          {:ok,
           %{
             state
             | in_cell: max(0, state.in_cell - 1),
               cell_texts: [],
               row_cells: [ct | state.row_cells]
           }}

        match_ns(name, "tblGrid") ->
          {:ok, %{state | in_table_grid: max(0, state.in_table_grid - 1)}}

        match_ns(name, "drawing") ->
          {st, img} = extract_img(state, state.image_rid, state.image_alt)
          blocks = if img, do: [img | st.blocks], else: st.blocks
          {:ok, %{st | in_drawing: max(0, st.in_drawing - 1), blocks: blocks}}

        match_ns(name, "docPr") ->
          {:ok, %{state | in_doc_pr: max(0, state.in_doc_pr - 1)}}

        name == "pic:blip" or name == "a:blip" or String.ends_with?(name, "}blip") ->
          {:ok, %{state | in_blip: max(0, state.in_blip - 1)}}

        match_ns(name, "headerReference") ->
          {:ok, %{state | in_header_ref: max(0, state.in_header_ref - 1)}}

        match_ns(name, "footerReference") ->
          {:ok, %{state | in_footer_ref: max(0, state.in_footer_ref - 1)}}

        match_ns(name, "tab") ->
          if state.in_run > 0 do
            {:ok, %{state | text_parts: ["\t" | state.text_parts]}}
          else
            {:ok, state}
          end

        match_ns(name, "br") ->
          if state.in_run > 0 do
            {:ok, %{state | text_parts: ["\n" | state.text_parts]}}
          else
            {:ok, state}
          end

        true ->
          {:ok, state}
      end
    end

    def handle_event(_, _, state), do: {:ok, state}
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # StylesHandler — parses word/styles.xml
  # ═════════════════════════════════════════════════════════════════════════════

  defmodule StylesHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    def handle_event(:start_element, {name, attrs}, acc)
        when name in [
               "w:style",
               "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}style"
             ] do
      am = Map.new(attrs)

      id =
        Map.get(am, "w:styleId") ||
          Map.get(am, "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}styleId")

      type =
        Map.get(am, "w:type") ||
          Map.get(am, "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}type")

      if type == "paragraph" and id != nil do
        {:ok, {:style, id, type, nil, acc}}
      else
        {:ok, acc}
      end
    end

    def handle_event(:start_element, {name, attrs}, {:style, id, type, _, acc})
        when name in [
               "w:name",
               "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}name"
             ] do
      am = Map.new(attrs)

      n =
        Map.get(am, "w:val") ||
          Map.get(am, "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}val")

      {:ok, {:style, id, type, n || "", acc}}
    end

    def handle_event(:start_element, _, {:style, id, type, buf, acc}),
      do: {:ok, {:style, id, type, buf, acc}}

    def handle_event(:start_element, _, acc), do: {:ok, acc}

    def handle_event(:characters, _, acc), do: {:ok, acc}

    def handle_event(:end_element, "w:style", {:style, id, _, n, acc}),
      do: {:ok, store_style(acc, id, n)}

    def handle_event(
          :end_element,
          "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}style",
          {:style, id, _, n, acc}
        ),
        do: {:ok, store_style(acc, id, n)}

    def handle_event(_, _, acc), do: {:ok, acc}

    defp store_style(acc, nil, _), do: acc
    defp store_style(acc, id, nil), do: Map.put(acc, String.downcase(id), "")
    defp store_style(acc, id, n), do: Map.put(acc, String.downcase(id), n)
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # NumberingHandler — builds %{num_map: %{id => abs_id},
  #                            abstract_levels: %{{abs_id, lvl} => fmt}}
  # ═════════════════════════════════════════════════════════════════════════════

  defmodule NumberingHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    def handle_event(:start_element, {name, attrs}, state) do
      cond do
        name in ["w:num", "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}num"] ->
          am = Map.new(attrs)

          nid =
            Map.get(am, "w:numId") ||
              Map.get(am, "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}numId")

          {:ok, %{state | current_num: nid && String.to_integer(nid)}}

        name in [
          "w:abstractNumId",
          "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}abstractNumId"
        ] ->
          am = Map.new(attrs)

          val =
            Map.get(am, "w:val") ||
              Map.get(am, "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}val")

          {:ok, %{state | current_abs_id: val && String.to_integer(val)}}

        name in [
          "w:abstractNum",
          "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}abstractNum"
        ] ->
          am = Map.new(attrs)

          aid =
            Map.get(am, "w:abstractNumId") ||
              Map.get(
                am,
                "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}abstractNumId"
              )

          {:ok, %{state | cur_abs_def: aid && String.to_integer(aid), in_abs: true}}

        name in ["w:lvl", "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}lvl"] ->
          am = Map.new(attrs)

          il =
            Map.get(am, "w:ilvl") ||
              Map.get(
                am,
                "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}ilvl",
                "0"
              )

          {:ok, %{state | current_ilvl: String.to_integer(il), in_lvl: true, current_fmt: nil}}

        name in [
          "w:numFmt",
          "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}numFmt"
        ] ->
          am = Map.new(attrs)

          v =
            Map.get(am, "w:val") ||
              Map.get(am, "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}val")

          {:ok, %{state | current_fmt: v}}

        true ->
          {:ok, state}
      end
    end

    def handle_event(:characters, _, state), do: {:ok, state}

    def handle_event(:end_element, name, state) do
      cond do
        name in ["w:num", "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}num"] ->
          if state.current_abs_id != nil and state.current_num != nil do
            {:ok,
             %{
               state
               | num_map: Map.put(state.num_map, state.current_num, state.current_abs_id),
                 current_num: nil,
                 current_abs_id: nil
             }}
          else
            {:ok, %{state | current_num: nil, current_abs_id: nil}}
          end

        name in [
          "w:abstractNum",
          "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}abstractNum"
        ] ->
          {:ok, %{state | cur_abs_def: nil, in_abs: false, current_ilvl: nil}}

        name in ["w:lvl", "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}lvl"] ->
          abs_id = state.cur_abs_def
          ilvl = state.current_ilvl
          fmt = state.current_fmt

          new_levels =
            if abs_id != nil and ilvl != nil and fmt != nil do
              Map.put(state.abstract_levels, {abs_id, ilvl}, fmt)
            else
              state.abstract_levels
            end

          {:ok, %{state | abstract_levels: new_levels, in_lvl: false, current_fmt: nil}}

        true ->
          {:ok, state}
      end
    end

    def handle_event(_, _, state), do: {:ok, state}
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # RelsHandler — parses word/_rels/document.xml.rels
  # ═════════════════════════════════════════════════════════════════════════════

  defmodule RelsHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    def handle_event(:start_element, {name, attrs}, acc)
        when name in [
               "Relationship",
               "{http://schemas.openxmlformats.org/package/2006/relationships}Relationship"
             ] do
      am = Map.new(attrs)

      rid =
        Map.get(am, "Id") ||
          Map.get(am, "{http://schemas.openxmlformats.org/package/2006/relationships}Id")

      target =
        Map.get(am, "Target") ||
          Map.get(am, "{http://schemas.openxmlformats.org/package/2006/relationships}Target")

      if rid && target, do: {:ok, Map.put(acc, rid, target)}, else: {:ok, acc}
    end

    def handle_event(_, _, acc), do: {:ok, acc}
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # CorePropsHandler
  # ═════════════════════════════════════════════════════════════════════════════

  defmodule CorePropsHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    def handle_event(:start_element, {name, _}, _)
        when name in ["title", "{http://purl.org/dc/elements/1.1/}title", "dc:title"],
        do: {:ok, {:title, ""}}

    def handle_event(:start_element, _, st), do: {:ok, st}

    def handle_event(:characters, chars, {:title, _}), do: {:ok, {:title, chars}}
    def handle_event(:characters, _, st), do: {:ok, st}

    def handle_event(:end_element, name, {:title, val})
        when name in ["title", "dc:title", "{http://purl.org/dc/elements/1.1/}title"],
        do: {:ok, val}

    def handle_event(:end_element, _, st), do: {:ok, st}
    def handle_event(_, _, st), do: {:ok, st}
  end
end
