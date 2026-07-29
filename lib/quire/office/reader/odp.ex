defmodule Quire.Office.Reader.Odp do
  @moduledoc """
  Reader for `.odp` (OpenDocument Presentation) files.

  Parses the ZIP archive, extracts slides from `content.xml`, then builds
  `Quire.Office.Layout` sections — one per slide — with `:heading`, `:paragraph`,
  and `:list_item` blocks.

  ## Supported constructs

    * Slide titles and text body content
    * Bulleted and numbered lists
    * Multi-slide presentations

  ## Unsupported (reported as notes)

    * Embedded images/drawings
    * Charts and SmartArt
    * Tables within presentations
    * Text formatting (fonts, colours, bold/italic)
    * Speaker notes
    * Transitions and animations
  """

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  @doc """
  Parse a `.odp` file from bytes.

  Returns `{:ok, Layout.t()}` or `{:error, reason}`.
  """
  @spec read(binary()) :: {:ok, Layout.t()} | {:error, atom()}
  def read(bytes) when is_binary(bytes) do
    case :zip.unzip(bytes, [:memory]) do
      {:ok, entries} ->
        entry_map = Map.new(entries, fn {name, data} -> {List.to_string(name), data} end)

        with {:ok, sections} <- parse_content(entry_map) do
          {:ok,
           %Layout{
             sections: sections,
             report: [
               %{level: :info, message: "Parsed #{length(sections)} slide(s)", source: "odp"}
             ]
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Content parsing ─────────────────────────────────────────────────────────

  defp parse_content(entry_map) do
    case Map.fetch(entry_map, "content.xml") do
      {:ok, xml} ->
        {:ok, state} =
          Saxy.parse_string(xml, __MODULE__.ContentHandler, %{
            sections: [],
            current_slide: nil,
            blocks: [],
            in_draw_page: 0,
            in_text_box: 0,
            in_text_p: 0,
            in_text_h: 0,
            in_text_list: 0,
            text: [],
            current_block: nil,
            heading_level: 1,
            first_frame: true
          })

        state = flush_slide(state)
        {:ok, Enum.reverse(state.sections)}

      :error ->
        {:error, :invalid_odp}
    end
  end

  # ── Block helpers ───────────────────────────────────────────────────────────

  @doc false
  def flush_block(%{current_block: nil} = state), do: state

  @doc false
  def flush_block(state) do
    text = state.text |> Enum.reverse() |> Enum.join("") |> String.trim()

    block =
      case state.current_block do
        :title when text != "" -> {:heading, text, 1}
        :heading when text != "" -> {:heading, text, state.heading_level}
        :body when text != "" -> {:paragraph, text}
        :list_item when text != "" -> {:list_item, text}
        _ -> nil
      end

    blocks = if block, do: [block | state.blocks], else: state.blocks
    %{state | blocks: blocks, current_block: nil, text: []}
  end

  @doc false
  def flush_slide(%{current_slide: nil} = state), do: state

  @doc false
  def flush_slide(state) do
    state = flush_block(state)
    blocks = group_lists(Enum.reverse(state.blocks))
    section = Section.new(:slide, state.current_slide) |> then(&%{&1 | blocks: blocks})
    %{state | sections: [section | state.sections], blocks: [], current_slide: nil}
  end

  # Group consecutive :list_item blocks into {:list, items, ordered}
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

  # Extract the local name from a potentially namespace-qualified element name.
  # Saxy delivers names as either "prefix:local" or "{urn:...}local".
  @doc false
  def local_name(name) do
    name |> String.split(~r/[:}]/) |> List.last()
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # SAX Handler
  # ═════════════════════════════════════════════════════════════════════════════

  defmodule ContentHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    def handle_event(:start_element, {name, attrs}, state) do
      cond do
        # <draw:page> — start a new slide
        local_name(name) == "page" ->
          state = flush_slide(state)
          m = Map.new(attrs)
          name_attr = slide_name(m)

          {:ok,
           %{
             state
             | current_slide: name_attr,
               blocks: [],
               first_frame: true,
               in_draw_page: state.in_draw_page + 1
           }}

        # <draw:text-box>
        String.ends_with?(name, "text-box") ->
          {:ok, %{state | in_text_box: state.in_text_box + 1}}

        # <text:list> inside a text-box
        String.ends_with?(name, "list") and
          state.in_text_box > 0 and
          not String.ends_with?(name, "list-item") and
            not String.ends_with?(name, "list-header") ->
          {:ok, %{state | in_text_list: state.in_text_list + 1}}

        # <text:h> — heading with outline level
        String.ends_with?(name, "h") and state.in_text_box > 0 ->
          m = Map.new(attrs)

          level_str =
            Map.get(
              m,
              "text:outline-level",
              Map.get(
                m,
                "{urn:oasis:names:tc:opendocument:xmlns:text:1.0}outline-level",
                "1"
              )
            )

          level = String.to_integer(level_str)
          state = flush_block(state)

          {:ok,
           %{
             state
             | in_text_h: state.in_text_h + 1,
               current_block: :heading,
               heading_level: level,
               text: []
           }}

        # <text:p> inside a text-box
        String.ends_with?(name, "p") and state.in_text_box > 0 ->
          block_type =
            cond do
              state.in_text_list > 0 -> :list_item
              state.first_frame -> :title
              true -> :body
            end

          state = flush_block(state)

          {:ok,
           %{
             state
             | in_text_p: state.in_text_p + 1,
               current_block: block_type,
               text: []
           }}

        true ->
          {:ok, state}
      end
    end

    def handle_event(:characters, chars, state) do
      if state.current_block != nil do
        {:ok, %{state | text: [chars | state.text]}}
      else
        {:ok, state}
      end
    end

    def handle_event(:end_element, name, state) do
      cond do
        # </text:p>
        String.ends_with?(name, "p") and state.in_text_p > 0 ->
          state = flush_block(%{state | in_text_p: state.in_text_p - 1})
          {:ok, state}

        # </text:h>
        String.ends_with?(name, "h") and state.in_text_h > 0 ->
          state = flush_block(%{state | in_text_h: state.in_text_h - 1})
          {:ok, state}

        # </text:list>
        String.ends_with?(name, "list") and
          state.in_text_list > 0 and
          not String.ends_with?(name, "list-item") and
            not String.ends_with?(name, "list-header") ->
          {:ok, %{state | in_text_list: state.in_text_list - 1}}

        # </draw:text-box>
        String.ends_with?(name, "text-box") and state.in_text_box > 0 ->
          {:ok, %{state | in_text_box: state.in_text_box - 1, first_frame: false}}

        # </draw:page> — finalize the slide
        local_name(name) == "page" and state.in_draw_page > 0 ->
          state = flush_slide(%{state | in_draw_page: state.in_draw_page - 1})
          {:ok, state}

        true ->
          {:ok, state}
      end
    end

    def handle_event(_, _, state), do: {:ok, state}

    # ── Private helpers ─────────────────────────────────────────────────────

    defp local_name(name), do: Quire.Office.Reader.Odp.local_name(name)

    defp slide_name(attrs) do
      Map.get(
        attrs,
        "draw:name",
        Map.get(attrs, "{urn:oasis:names:tc:opendocument:xmlns:drawing:1.0}name", "")
      )
    end

    defp flush_block(state), do: Quire.Office.Reader.Odp.flush_block(state)
    defp flush_slide(state), do: Quire.Office.Reader.Odp.flush_slide(state)
  end
end
