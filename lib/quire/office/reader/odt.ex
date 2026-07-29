defmodule Quire.Office.Reader.Odt do
  @moduledoc """
  Reader for `.odt` (OpenDocument Text) files.

  Parses the ZIP archive, extracts the document content from `content.xml`,
  then builds `Quire.Office.Layout` sections with `:paragraph`, `:heading`,
  and `:list` blocks.

  ## Supported constructs

    * Paragraphs (`<text:p>`)
    * Headings (`<text:h>` with `text:outline-level`)
    * Unordered lists (`<text:list>` with `<text:list-item>`)
    * Document title from `<dc:title>` in `meta.xml`
    * Inline spans (`<text:span>`)

  ## Unsupported (reported as notes)

    * Images/drawings
    * Tables (`<table:table>`)
    * Text formatting (fonts, colours, bold/italic)
    * Nested lists
    * Footnotes/endnotes
    * Tracked changes
    * Embedded objects
  """

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  @doc """
  Parse a `.odt` file from bytes.

  Returns `{:ok, Layout.t()}` or `{:error, reason}`.
  """
  @spec read(binary()) :: {:ok, Layout.t()} | {:error, atom()}
  def read(bytes) when is_binary(bytes) do
    case :zip.unzip(bytes, [:memory]) do
      {:ok, entries} ->
        entry_map = Map.new(entries, fn {name, data} -> {List.to_string(name), data} end)

        with {:ok, content_xml} <- Map.fetch(entry_map, "content.xml"),
             {:ok, blocks} <- parse_content(content_xml) do
          title = extract_title(entry_map)
          grouped = group_lists(blocks)

          section =
            Section.new(:page, nil)
            |> then(fn s -> %{s | blocks: grouped} end)

          {:ok,
           %Layout{
             title: title,
             sections: [section],
             report: [
               %{level: :info, message: "Parsed 1 document", source: "odt"}
             ]
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Content parsing ─────────────────────────────────────────────────────────

  defp parse_content(xml) do
    initial_state = %{
      blocks: [],
      current_block: nil,
      text_parts: [],
      level: 0,
      in_office_text: 0,
      in_p: 0,
      in_span: 0,
      in_list: 0,
      in_list_item: 0
    }

    case Saxy.parse_string(xml, __MODULE__.ContentHandler, initial_state) do
      {:ok, state} ->
        state = flush_block(state)
        {:ok, Enum.reverse(state.blocks)}

      {:error, _reason} ->
        {:error, :invalid_odt}
    end
  end

  # ── List grouping ───────────────────────────────────────────────────────────
  #
  # Group consecutive :list_item blocks into {:list, items, false} blocks,
  # matching the pattern used by Pptx.

  defp group_lists(blocks), do: do_group_lists(blocks, [], [])

  defp do_group_lists([{:list_item, item} | rest], list_acc, result),
    do: do_group_lists(rest, [item | list_acc], result)

  defp do_group_lists([block | rest], [], result),
    do: do_group_lists(rest, [], [block | result])

  defp do_group_lists([block | rest], list_acc, result),
    do: do_group_lists([block | rest], [], [{:list, Enum.reverse(list_acc), false} | result])

  defp do_group_lists([], [], result), do: Enum.reverse(result)

  defp do_group_lists([], list_acc, result),
    do: Enum.reverse([{:list, Enum.reverse(list_acc), false} | result])

  # ── Block helpers ───────────────────────────────────────────────────────────

  defp flush_block(%{current_block: nil} = state), do: state

  defp flush_block(state) do
    text = state.text_parts |> Enum.reverse() |> Enum.join("") |> String.trim()

    block =
      case state.current_block do
        :heading when text != "" -> {:heading, text, state.level}
        :paragraph when text != "" -> {:paragraph, text}
        :list_item when text != "" -> {:list_item, text}
        _ -> nil
      end

    blocks = if block, do: [block | state.blocks], else: state.blocks
    %{state | blocks: blocks, current_block: nil, text_parts: [], level: 0}
  end

  # ── Title from meta.xml ─────────────────────────────────────────────────────

  defp extract_title(entry_map) do
    case Map.fetch(entry_map, "meta.xml") do
      {:ok, xml} ->
        {:ok, title} = Saxy.parse_string(xml, __MODULE__.MetaHandler, nil)
        title

      :error ->
        nil
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # SAX Handlers
  # ═════════════════════════════════════════════════════════════════════════════

  defmodule ContentHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    @doc false
    def handle_event(:start_element, {name, attrs}, state) do
      cond do
        # office:text — main content container
        name == "office:text" or String.ends_with?(name, "}text") ->
          {:ok, %{state | in_office_text: state.in_office_text + 1}}

        # text:p — paragraph (inside office:text context)
        (name == "text:p" or String.ends_with?(name, "}p")) and state.in_office_text > 0 ->
          state = flush_block(state)
          block_type = if state.in_list_item > 0, do: :list_item, else: :paragraph
          {:ok, %{state | current_block: block_type, in_p: state.in_p + 1}}

        # text:h — heading with outline level
        (name == "text:h" or String.ends_with?(name, "}h")) and state.in_office_text > 0 ->
          state = flush_block(state)
          level = extract_level(attrs)
          {:ok, %{state | current_block: :heading, level: level, in_p: state.in_p + 1}}

        # text:span — styled text run, collect characters
        name == "text:span" or String.ends_with?(name, "}span") ->
          {:ok, %{state | in_span: state.in_span + 1}}

        # text:list — unordered list container
        (name == "text:list" or String.ends_with?(name, "}list")) and state.in_office_text > 0 ->
          {:ok, %{state | in_list: state.in_list + 1}}

        # text:list-item — individual list item
        name == "text:list-item" or String.ends_with?(name, "}list-item") ->
          {:ok, %{state | in_list_item: state.in_list_item + 1}}

        true ->
          {:ok, state}
      end
    end

    @doc false
    def handle_event(:characters, chars, state) do
      # Collect text when inside a paragraph/heading or inside a span
      if state.in_span > 0 or state.in_p > 0 do
        {:ok, %{state | text_parts: [chars | state.text_parts]}}
      else
        {:ok, state}
      end
    end

    @doc false
    def handle_event(:end_element, name, state) do
      cond do
        name == "office:text" or String.ends_with?(name, "}text") ->
          {:ok, %{state | in_office_text: max(0, state.in_office_text - 1)}}

        (name == "text:p" or String.ends_with?(name, "}p")) and state.in_p > 0 ->
          state = flush_block(%{state | in_p: state.in_p - 1})
          {:ok, state}

        (name == "text:h" or String.ends_with?(name, "}h")) and state.in_p > 0 ->
          state = flush_block(%{state | in_p: state.in_p - 1})
          {:ok, state}

        name == "text:span" or String.ends_with?(name, "}span") ->
          {:ok, %{state | in_span: max(0, state.in_span - 1)}}

        name == "text:list" or String.ends_with?(name, "}list") ->
          {:ok, %{state | in_list: max(0, state.in_list - 1)}}

        name == "text:list-item" or String.ends_with?(name, "}list-item") ->
          {:ok, %{state | in_list_item: max(0, state.in_list_item - 1)}}

        true ->
          {:ok, state}
      end
    end

    @doc false
    def handle_event(_, _, state), do: {:ok, state}

    # ── Internal helpers ─────────────────────────────────────────────────────

    defp flush_block(%{current_block: nil} = state), do: state

    defp flush_block(state) do
      text = state.text_parts |> Enum.reverse() |> Enum.join("") |> String.trim()

      block =
        case state.current_block do
          :heading when text != "" -> {:heading, text, state.level}
          :paragraph when text != "" -> {:paragraph, text}
          :list_item when text != "" -> {:list_item, text}
          _ -> nil
        end

      blocks = if block, do: [block | state.blocks], else: state.blocks
      %{state | blocks: blocks, current_block: nil, text_parts: [], level: 0}
    end

    defp extract_level(attrs) do
      level_str =
        Enum.find_value(attrs, "1", fn {key, val} ->
          if String.ends_with?(key, "outline-level"), do: val, else: nil
        end)

      level = String.to_integer(level_str)

      cond do
        level < 1 -> 1
        level > 6 -> 6
        true -> level
      end
    end
  end

  defmodule MetaHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    @doc false
    def handle_event(:start_element, {name, _}, _state)
        when name in [
               "title",
               "{http://purl.org/dc/elements/1.1/}title",
               "dc:title"
             ],
        do: {:ok, {:title, ""}}

    def handle_event(:start_element, _, state), do: {:ok, state}

    @doc false
    def handle_event(:characters, chars, {:title, _}), do: {:ok, {:title, chars}}
    def handle_event(:characters, _, state), do: {:ok, state}

    @doc false
    def handle_event(:end_element, "title", {:title, val}), do: {:ok, val}
    def handle_event(:end_element, _, state), do: {:ok, state}
  end
end
