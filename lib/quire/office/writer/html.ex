defmodule Quire.Office.Writer.Html do
  @moduledoc """
  Renders a `Quire.Office.Layout.t()` to an HTML string for chromic_pdf PDF
  conversion (T-072).

  The HTML is a self-contained document with inline CSS and data URIs for
  images (embedded as base64). No external assets, no JavaScript — the output
  is designed to be fed directly to chromic_pdf.

  ## Supported blocks

    * `{:paragraph, text}` → `<p>`
    * `{:heading, text, level}` → `<h1>`–`<h6>`
    * `{:list, items, ordered}` → `<ul>` / `<ol>`
    * `{:table, headers, rows}` → `<table>` with `<thead>` / `<tbody>`
    * `{:image, bytes, alt, ext}` → `<img>` with `data:` URI

  ## Conversion report notes

  Notes are rendered as a `<div class="conversion-report">` at the end of the
  document body so that chromic_pdf captures them.
  """

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  @doc """
  Render a complete Layout to HTML.

  Returns `{:ok, html_string}`.

  ## Examples

      {:ok, html} = Quire.Office.Writer.Html.write(layout, :html, [])
  """
  @spec write(Layout.t(), atom(), keyword()) :: {:ok, String.t()}
  def write(%Layout{} = layout, :html, _opts \\ []) do
    sections_html =
      layout.sections
      |> Enum.map_join("\n", &render_section/1)

    report_html = render_report(layout.report)

    html = ~s"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      #{title_tag(layout.title)}
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Noto Sans", Helvetica, Arial, sans-serif; font-size: 12pt; line-height: 1.6; color: #1a1a1a; padding: 1in; }
        h1 { font-size: 2em; margin: 0.67em 0; }
        h2 { font-size: 1.5em; margin: 0.75em 0; }
        h3 { font-size: 1.17em; margin: 0.83em 0; }
        h4 { font-size: 1em; margin: 1.12em 0; }
        h5 { font-size: 0.83em; margin: 1.5em 0; }
        h6 { font-size: 0.75em; margin: 1.67em 0; }
        p { margin: 0.5em 0; }
        ul, ol { padding-left: 2em; margin: 0.5em 0; }
        li { margin: 0.25em 0; }
        table { border-collapse: collapse; width: 100%; margin: 0.5em 0; }
        th, td { border: 1px solid #ccc; padding: 6px 10px; text-align: left; vertical-align: top; }
        th { background: #f2f2f2; font-weight: 600; }
        tr:nth-child(even) td { background: #fafafa; }
        img { max-width: 100%; height: auto; }
        .conversion-report { margin-top: 2em; padding: 1em; border: 1px solid #e5e5e5; background: #fafafa; font-size: 10pt; color: #555; }
        .conversion-report h2 { font-size: 1.2em; margin: 0 0 0.5em; }
        .conversion-report ul { list-style: none; padding: 0; }
        .conversion-report li { margin: 0.25em 0; padding: 0.25em 0.5em; }
        .conversion-report .unsupported { color: #b91c1c; }
        .conversion-report .warn { color: #b45309; }
        .conversion-report .info { color: #1d4ed8; }
      </style>
    </head>
    <body>
      #{sections_html}
      #{report_html}
    </body>
    </html>
    """

    {:ok, html}
  end

  # ── Section rendering ────────────────────────────────────────────────────

  defp render_section(%Section{type: type, title: title, blocks: blocks}) do
    title_tag = if title, do: ~s|<h1 class="section-title">#{escape(title)}</h1>\n|, else: ""
    class = section_class(type)
    blocks_html = Enum.map_join(blocks, "\n", &render_block/1)

    ~s|<div class="#{class}">\n#{title_tag}#{blocks_html}\n</div>|
  end

  defp section_class(:page), do: "section-page"
  defp section_class(:sheet), do: "section-sheet"
  defp section_class(:slide), do: "section-slide"

  # ── Block rendering ──────────────────────────────────────────────────────

  defp render_block({:paragraph, text}) do
    ~s|<p>#{escape(text)}</p>|
  end

  defp render_block({:heading, text, level}) when level in 1..6 do
    ~s|<h#{level}>#{escape(text)}</h#{level}>|
  end

  # Clamp out-of-range levels to valid range
  defp render_block({:heading, text, level}) do
    render_block({:heading, text, min(max(level, 1), 6)})
  end

  defp render_block({:list, items, ordered}) do
    tag = if ordered, do: "ol", else: "ul"

    items_html =
      Enum.map_join(items, "\n", fn item ->
        ~s|  <li>#{escape(item)}</li>|
      end)

    ~s|<#{tag}>\n#{items_html}\n</#{tag}>|
  end

  defp render_block({:table, headers, rows}) do
    headers_html =
      if headers != [] do
        thead =
          Enum.map_join(headers, "\n", fn h ->
            ~s|    <th>#{escape(h)}</th>|
          end)

        ~s|  <thead>\n#{thead}\n  </thead>\n|
      else
        ""
      end

    rows_html =
      Enum.map_join(rows, "\n", fn row ->
        cells =
          Enum.map_join(row, "\n", fn cell ->
            ~s|      <td>#{escape(cell)}</td>|
          end)

        ~s|    <tr>\n#{cells}\n    </tr>|
      end)

    tbody =
      if rows_html != "" do
        ~s|  <tbody>\n#{rows_html}\n  </tbody>\n|
      else
        ""
      end

    ~s|<table>\n#{headers_html}#{tbody}</table>|
  end

  defp render_block({:image, bytes, alt, ext}) do
    mime = mime_type(ext)
    b64 = Base.encode64(bytes)
    ~s|<img src="data:#{mime};base64,#{b64}" alt="#{escape(alt)}"/>|
  end

  # Fallback for unknown/future block types — renders a visible placeholder
  defp render_block(unknown) do
    ~s|<p class="unknown-block">[Unsupported block: #{escape(inspect(unknown))}]</p>|
  end

  # ── Report rendering ─────────────────────────────────────────────────────

  defp render_report([]), do: ""

  defp render_report(notes) do
    items =
      Enum.map_join(notes, "\n", fn note ->
        level_class = to_string(note.level)

        ~s|    <li class="#{level_class}">#{escape(note.message)} <em>(#{escape(note.source)})</em></li>|
      end)

    ~s|<div class="conversion-report">\n<h2>Conversion Report</h2>\n<ul>\n#{items}\n  </ul>\n</div>|
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s["], "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp escape(nil), do: ""

  defp title_tag(nil), do: ""

  defp title_tag(title) when is_binary(title) and title != "" do
    ~s|    <title>#{escape(title)}</title>\n|
  end

  defp title_tag(_), do: ""

  defp mime_type("png"), do: "image/png"
  defp mime_type("jpg"), do: "image/jpeg"
  defp mime_type("jpeg"), do: "image/jpeg"
  defp mime_type("gif"), do: "image/gif"
  defp mime_type("bmp"), do: "image/bmp"
  defp mime_type("webp"), do: "image/webp"
  defp mime_type("svg"), do: "image/svg+xml"
  defp mime_type("tiff"), do: "image/tiff"
  defp mime_type("tif"), do: "image/tiff"
  defp mime_type(_), do: "application/octet-stream"
end
