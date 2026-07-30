defmodule Quire.Office.Writer.Rtf do
  @moduledoc ~S"""
  Renders a `Quire.Office.Layout.t()` to an RTFv1 string.

  Basic formatting only — bold, italic, underline, font size.  No embedded
  images, no complex layout.  The output is designed to be opened in any
  word processor that supports RTF.

  ## RTFv1 document structure

      {\rtf1\ansi\deff0      ← header
      {\fonttbl ...}          ← font table (Liberation Serif/Sans/Mono)
      {\colortbl ...}         ← colour table
      \viewkind4\uc1\pard\plain\f0\fs24  ← defaults
      ...body...
      }                       ← closing brace

  ## Supported blocks

    * `{:paragraph, text}` → plain paragraph
    * `{:heading, text, level}` → heading with bold + size
    * `{:list, items, ordered}` → unordered / ordered list
    * `{:table, headers, rows}` → simple grid table (no merged cells)
    * `{:image, _, _, _}` → **skipped** (basic formatting only)

  Images are silently dropped because RTF embedding is outside scope.
  """

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  @doc """
  Render a complete Layout to RTF.

  Returns `{:ok, rtf_string}`.

  ## Examples

      {:ok, rtf} = Quire.Office.Writer.Rtf.write(layout, :rtf, [])
  """
  @spec write(Layout.t(), atom(), keyword()) :: {:ok, String.t()}
  def write(%Layout{} = layout, :rtf, _opts \\ []) do
    header = ~c"{\\rtf1\\ansi\\deff0"
    fonttbl = build_fonttbl()
    colortbl = build_colortbl()

    body =
      layout.sections
      |> Enum.map_join("\n", &render_section/1)

    rtf =
      [
        header,
        fonttbl,
        colortbl,
        ~c"\\viewkind4\\uc1\\pard\\plain\\f0\\fs24 ",
        body,
        ?}
      ]
      |> IO.iodata_to_binary()

    {:ok, rtf}
  end

  # ── Header ──────────────────────────────────────────────────────────────

  defp build_fonttbl do
    ~c'{\\fonttbl{\\f0\\fswiss\\fcharset0 Liberation Sans;}{\\f1\\froman\\fcharset0 Liberation Serif;}{\\f2\\fmodern\\fcharset0 Liberation Mono;}}'
  end

  defp build_colortbl do
    ~c'{\\colortbl ;\\red0\\green0\\blue0;}'
  end

  # ── Section rendering ────────────────────────────────────────────────────

  defp render_section(%Section{type: _type, title: title, blocks: blocks}) do
    title_rtf =
      if title && title != "" do
        "{\\pard\\plain\\f1\\fs36\\b " <> escape(title) <> "\\par}\n"
      else
        ""
      end

    blocks_rtf =
      blocks
      |> Enum.map_join("\n", &render_block/1)

    "{\\sect\\sectd\\sbknone\n" <> title_rtf <> blocks_rtf <> "\n\\sect}"
  end

  # ── Block rendering ──────────────────────────────────────────────────────

  defp render_block({:paragraph, text}) do
    "{\\pard\\plain\\f0\\fs24 " <> escape(text) <> "\\par}"
  end

  defp render_block({:heading, text, level}) do
    size = heading_size(level)
    "{\\pard\\plain\\f1\\fs" <> Integer.to_string(size) <> "\\b " <> escape(text) <> "\\par}"
  end

  defp render_block({:list, items, ordered}) do
    list_group =
      if ordered do
        # Numbered list using RTF paragraph numbering
        items
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {item, _idx} ->
          "{\\pard\\plain\\f0\\fs24\\fi-240\\li480 " <>
            "{\\pn\\pnlvlbody\\pnindent\\pnstart1\\pndec{\\pntxtb .}}" <>
            escape(item) <> "\\par}"
        end)
      else
        # Bullet list using RTF paragraph numbering
        Enum.map_join(items, "\n", fn item ->
          "{\\pard\\plain\\f0\\fs24\\fi-240\\li480 " <>
            "{\\pntext\\f2\\'B7}" <>
            escape(item) <> "\\par}"
        end)
      end

    list_group
  end

  defp render_block({:table, headers, rows}) do
    header_part = if headers != [], do: render_table_row(headers, true), else: ""
    body_part = Enum.map_join(rows, "\n", &render_table_row(&1, false))
    header_part <> body_part
  end

  # Images silently dropped — basic formatting only
  defp render_block({:image, _bytes, _alt, _ext}), do: ""

  # Fallback for unknown block types
  defp render_block(unknown) do
    "{\\pard\\plain\\f0\\fs24 [Unsupported: " <> escape(inspect(unknown)) <> "]\\par}"
  end

  # ── Table row helper ─────────────────────────────────────────────────────

  defp render_table_row(cells, is_header) do
    cell_count = length(cells)
    cell_width = div(9000, max(cell_count, 1))

    cell_defs =
      Enum.reduce(cells, {[], cell_width}, fn _cell, {acc, x} ->
        {[~c"\\cellx" ++ Integer.to_charlist(x) | acc], x + cell_width}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    cell_contents =
      Enum.map(cells, fn cell ->
        fmt = if is_header, do: "\\b\\fs24 ", else: "\\fs24 "
        " " <> fmt <> escape(cell) <> "\\cell"
      end)
      |> IO.iodata_to_binary()

    "{\\trowd\\trgaph0\\trqc " <> cell_defs <> cell_contents <> "\\row}"
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # 36 pt
  defp heading_size(level) when level <= 1, do: 72
  # 28 pt
  defp heading_size(2), do: 56
  # 24 pt
  defp heading_size(3), do: 48
  # 20 pt
  defp heading_size(4), do: 40
  # 18 pt
  defp heading_size(5), do: 36
  # 16 pt
  defp heading_size(_), do: 32

  @doc """
  Escape text for RTF — braces, backslashes, newlines, and non-ASCII.

  RTF special chars:
    * `{` → `\{`
    * `}` → `\}`
    * `\` → `\\`
    * CR/LF → `\\par `
    * Non-ASCII → `\\uNNNN?` (Unicode code point + fallback)
  """
  @spec escape(String.t() | nil) :: IO.chardata()
  def escape(nil), do: ""

  def escape(text) when is_binary(text) do
    text
    |> String.to_charlist()
    |> Enum.flat_map(&escape_char/1)
  end

  defp escape_char(?\\), do: ~c'\\\\'
  defp escape_char(?{), do: ~c'\\{'
  defp escape_char(?}), do: ~c'\\}'
  defp escape_char(?\r), do: ~c'\\par '
  defp escape_char(?\n), do: ~c'\\par '
  defp escape_char(c) when c >= 32 and c <= 126, do: [c]
  defp escape_char(c), do: ~c"\\u" ++ Integer.to_charlist(c) ++ ~c'?'
end
