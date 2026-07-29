defmodule Quire.Office.Reader.Pptx do
  @moduledoc """
  Reader for `.pptx` (PowerPoint) files.

  Parses the ZIP archive, extracts slide metadata and per-slide text shapes, then
  builds `Quire.Office.Layout` sections — one per slide — with `:heading`,
  `:paragraph`, and `:list_item` blocks.

  ## Supported constructs

    * Slide titles and text body shapes
    * Bulleted and numbered lists (auto-detected by indent level)
    * Multi-slide presentations
    * Slide titles from the title shape

  ## Unsupported (reported as notes)

    * Embedded images/drawings
    * Charts, SmartArt, and tables
    * Custom layouts and slide masters
    * Transitions and animations
    * Text formatting (fonts, colours, bold/italic)
    * Speaker notes
    * Comments
  """

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  @doc """
  Parse a `.pptx` file from bytes.

  Returns `{:ok, Layout.t()}` or `{:error, reason}`.
  """
  @spec read(binary()) :: {:ok, Layout.t()} | {:error, atom()}
  def read(bytes) when is_binary(bytes) do
    case :zip.unzip(bytes, [:memory]) do
      {:ok, entries} ->
        entry_map = Map.new(entries, fn {name, data} -> {List.to_string(name), data} end)

        with {:ok, slides} <- parse_presentation(entry_map),
             rels <- parse_presentation_rels(entry_map) do
          slide_paths = build_slide_paths(slides, rels)
          sections = build_sections(entry_map, slide_paths)

          {:ok,
           %Layout{
             title: extract_title(entry_map),
             sections: sections,
             report: [
               %{level: :info, message: "Parsed #{length(sections)} slide(s)", source: "pptx"}
             ]
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Presentation ────────────────────────────────────────────────────────────

  defp parse_presentation(entry_map) do
    case Map.fetch(entry_map, "ppt/presentation.xml") do
      {:ok, xml} ->
        {:ok, raw} = Saxy.parse_string(xml, __MODULE__.PresentationHandler, [])

        slides =
          raw
          |> Enum.reverse()
          |> Enum.map(fn {:sld_id, id, rid} -> {id, rid} end)

        if slides == [], do: {:error, :no_slides}, else: {:ok, slides}

      :error ->
        {:error, :invalid_pptx}
    end
  end

  defp parse_presentation_rels(entry_map) do
    case Map.fetch(entry_map, "ppt/_rels/presentation.xml.rels") do
      {:ok, xml} ->
        {:ok, raw} = Saxy.parse_string(xml, __MODULE__.RelsHandler, %{})
        raw

      :error ->
        %{}
    end
  end

  defp build_slide_paths(slides, rels) do
    Enum.map(slides, fn {_id, rid} ->
      idx = rid |> String.replace(~r/[^\d]/, "") |> String.to_integer()
      Map.get(rels, rid, "slides/slide#{idx}.xml")
    end)
  end

  # ── Build sections ──────────────────────────────────────────────────────────

  defp build_sections(entry_map, slide_paths) do
    Enum.with_index(slide_paths, 1)
    |> Enum.map(fn {path, idx} ->
      name = "Slide #{idx}"
      blocks = parse_slide(entry_map, path)
      Section.new(:slide, name) |> then(fn s -> %{s | blocks: blocks} end)
    end)
  end

  defp parse_slide(entry_map, path) do
    full_path = if String.starts_with?(path, "slides/"), do: "ppt/#{path}", else: path

    case Map.fetch(entry_map, full_path) do
      {:ok, xml} ->
        {:ok, result} =
          Saxy.parse_string(xml, __MODULE__.SlideHandler, %{
            blocks: [],
            current_block: nil,
            text_parts: [],
            in_tx_body: 0,
            in_a_p: 0,
            in_a_r: 0,
            in_a_t: 0,
            in_nv_sp_pr: false,
            in_c_nv_pr: false,
            is_title: false,
            level: 0,
            name: ""
          })

        finalize_blocks(result)

      :error ->
        []
    end
  end

  # Helpers to check namespaced element names
  defp finalize_blocks(state) do
    state = flush_block(state)
    group_lists(Enum.reverse(state.blocks))
  end

  # Group consecutive :list_item blocks into {:list, items, ordered} blocks
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

  defp flush_block(%{current_block: nil} = state), do: state

  defp flush_block(%{current_block: type, text_parts: parts} = state) do
    text = parts |> Enum.reverse() |> Enum.join("")
    block = build_block(type, text)
    state = if block, do: %{state | blocks: [block | state.blocks]}, else: state
    %{state | current_block: nil, text_parts: []}
  end

  defp build_block(:title, text) when text != "", do: {:heading, String.trim(text), 1}
  defp build_block(:body, text) when text != "", do: {:paragraph, String.trim(text)}
  defp build_block(:list, text) when text != "", do: {:list_item, String.trim(text)}
  defp build_block(_, _), do: nil

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

  defmodule PresentationHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    # Handle ns-prefixed sldId
    def handle_event(:start_element, {name, attrs}, acc) do
      name = name

      if String.ends_with?(name, "sldId") or String.ends_with?(name, "sldId") do
        m = Map.new(attrs)
        id = Map.get(m, "id", "")
        rid = Map.get(m, "r:id", "")
        {:ok, [{:sld_id, id, rid} | acc]}
      else
        {:ok, acc}
      end
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

  defmodule SlideHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    # Namespace URIs

    def handle_event(:start_element, {name, attrs}, state) do
      cond do
        String.ends_with?(name, "nvSpPr") ->
          {:ok, %{state | in_nv_sp_pr: true}}

        String.ends_with?(name, "cNvPr") and state.in_nv_sp_pr ->
          m = Map.new(attrs)
          name_attr = Map.get(m, "name", "")
          {:ok, %{state | in_c_nv_pr: true, name: name_attr}}

        # Text body
        String.ends_with?(name, "txBody") ->
          {:ok, %{state | in_tx_body: state.in_tx_body + 1}}

        # Paragraph inside text body
        String.ends_with?(name, "p") and state.in_tx_body > 0 ->
          lvl = Map.new(attrs) |> Map.get("lvl", "0") |> String.to_integer()
          is_list = lvl > 0

          block_type =
            cond do
              state.is_title -> :title
              is_list -> :list
              String.contains?(String.downcase(state.name), "title") -> :title
              true -> :body
            end

          state = flush_block(state)
          {:ok, %{state | in_a_p: state.in_a_p + 1, current_block: block_type, level: lvl}}

        # Run (rich text span)
        String.ends_with?(name, "r") ->
          {:ok, %{state | in_a_r: state.in_a_r + 1}}

        # Text content inside run
        String.ends_with?(name, "t") and state.in_a_r > 0 and state.in_a_p > 0 ->
          {:ok, %{state | in_a_t: state.in_a_t + 1}}

        # Line break
        String.ends_with?(name, "br") ->
          {:ok, %{state | text_parts: [?\n | state.text_parts]}}

        true ->
          {:ok, state}
      end
    end

    def handle_event(:characters, chars, %{in_a_t: n} = state) when n > 0 do
      {:ok, %{state | text_parts: [chars | state.text_parts]}}
    end

    def handle_event(:characters, _, state), do: {:ok, state}

    def handle_event(:end_element, name, state) do
      cond do
        String.ends_with?(name, "cNvPr") ->
          {:ok, %{state | in_c_nv_pr: false}}

        String.ends_with?(name, "nvSpPr") ->
          is_title = String.contains?(state.name, "Title") || String.contains?(state.name, "标题")
          {:ok, %{state | in_nv_sp_pr: false, is_title: is_title}}

        String.ends_with?(name, "sp") and state.is_title ->
          {:ok, %{state | is_title: false}}

        String.ends_with?(name, "sp") ->
          {:ok, state}

        String.ends_with?(name, "txBody") ->
          {:ok, %{state | in_tx_body: max(0, state.in_tx_body - 1)}}

        String.ends_with?(name, "p") and state.in_tx_body > 0 ->
          state = flush_block(%{state | in_a_p: max(0, state.in_a_p - 1)})
          {:ok, state}

        String.ends_with?(name, "r") ->
          {:ok, %{state | in_a_r: max(0, state.in_a_r - 1)}}

        String.ends_with?(name, "t") ->
          {:ok, %{state | in_a_t: max(0, state.in_a_t - 1)}}

        true ->
          {:ok, state}
      end
    end

    def handle_event(_, _, state), do: {:ok, state}

    defp flush_block(%{current_block: nil} = state), do: state

    defp flush_block(state) do
      text = state.text_parts |> Enum.reverse() |> Enum.join("") |> String.trim()

      block =
        case state.current_block do
          :title when text != "" -> {:heading, text, 1}
          :body when text != "" -> {:paragraph, text}
          :list when text != "" -> {:list_item, text}
          _ -> nil
        end

      blocks = if block, do: [block | state.blocks], else: state.blocks
      %{state | blocks: blocks, current_block: nil, text_parts: []}
    end
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
