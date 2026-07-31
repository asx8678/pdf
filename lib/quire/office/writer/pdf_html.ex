defmodule Quire.Office.Writer.PdfHtml do
  @moduledoc """
  PDF → self-contained HTML export (T-078).

  Generates the HTML entirely in Elixir: no external tool is involved
  (§3.3). Two modes:

    * `:overlay` (default) — each page is rendered to WebP and embedded as a
      `data:` URI; text spans from `Render.extract_text/2` are absolutely
      positioned over the page image using the §14.3 geometry conversions in
      `Quire.Geometry.span_to_css/4`. The span text is transparent so the
      raster shows through, but the text is selectable and searchable at the
      correct locations.

    * `:text_only` — semantic reflow: spans are grouped into visual lines and
      emitted as flowing paragraphs with no page images.

  The output is a single file with no external asset references — it renders
  fully offline.

  ## Options

    * `:mode` — `:overlay` (default) | `:text_only`
    * `:dpi` — render resolution for the page images (default 150)
    * `:title` — document `<title>` (default "Converted from PDF")
    * `:webp_quality` — WebP encode quality 1–100 (default 80)
  """

  alias Quire.Geometry
  alias Quire.Render
  alias Quire.Storage.Ref

  @default_dpi 150
  @default_webp_quality 80

  @doc """
  Convert a PDF storage ref to a self-contained HTML string.

  Returns `{:ok, html}` or `{:error, reason}`.
  """
  @spec write(Ref.t(), :html, keyword()) :: {:ok, String.t()} | {:error, term()}
  def write(ref, :html, opts \\ []) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :overlay)
    dpi = Keyword.get(opts, :dpi, @default_dpi)
    title = Keyword.get(opts, :title) || "Converted from PDF"
    webp_quality = Keyword.get(opts, :webp_quality, @default_webp_quality)

    with {:ok, pages} <- Render.page_geometry(ref),
         {:ok, text_pages} <- Render.extract_text(ref, []) do
      body =
        case mode do
          :overlay -> overlay_body(ref, pages, text_pages, dpi, webp_quality)
          :text_only -> text_only_body(pages, text_pages)
          other -> {:error, {:invalid_mode, other}}
        end

      case body do
        {:ok, body_html} -> {:ok, build_document(title, mode, body_html)}
        {:error, _} = err -> err
      end
    end
  end

  # ── Overlay mode ─────────────────────────────────────────────────────────

  # Each page: a positioned container holding the WebP data-URI image plus
  # absolutely positioned, transparent-but-selectable text spans.
  defp overlay_body(ref, pages, text_pages, dpi, webp_quality) do
    text_by_page = Map.new(text_pages, fn tp -> {tp.page, tp.spans || []} end)
    scale = dpi / 72

    Enum.reduce_while(Enum.with_index(pages), {:ok, []}, fn {page, index}, {:ok, acc} ->
      case render_page_webp(ref, page, index, dpi, webp_quality) do
        {:ok, data_uri} ->
          spans_html = overlay_spans(Map.get(text_by_page, index, []), page, index, scale)
          width_px = round(page.width * scale)
          height_px = round(page.height * scale)

          section =
            ~s|<section class="page" data-page="#{index}" style="position:relative;width:#{width_px}px;height:#{height_px}px;margin:0 auto 16px;box-shadow:0 1px 4px rgba(0,0,0,.25)">\n<img src="#{data_uri}" alt="Page #{index + 1}" width="#{width_px}" height="#{height_px}" style="display:block;max-width:none"/>\n#{spans_html}</section>|

          {:cont, {:ok, [section | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:render_page, index, reason}}}
      end
    end)
    |> case do
      {:ok, sections} -> {:ok, Enum.reverse(sections) |> Enum.join("\n")}
      {:error, _} = err -> err
    end
  end

  defp overlay_spans(spans, page, _index, scale) do
    Enum.map_join(spans, "\n", fn span ->
      case span.bounds do
        nil ->
          ""

        bounds ->
          css = Geometry.span_to_css(bounds, page.width, page.height, page.rotate)

          left = css.left * scale
          top = css.top * scale
          width = css.width * scale
          height = css.height * scale

          ~s|<span class="t" style="position:absolute;left:#{left}px;top:#{top}px;width:#{width}px;height:#{height}px;color:transparent;background:transparent;white-space:pre;overflow:hidden;">#{escape(span.text)}</span>|
      end
    end)
  end

  # ── Text-only mode ───────────────────────────────────────────────────────

  # Semantic reflow: spans grouped into visual lines, each line a paragraph.
  # Pages become <section> blocks in reading order; no images.
  defp text_only_body(_pages, text_pages) do
    sections =
      Enum.map_join(text_pages, "\n", fn tp ->
        paragraphs =
          tp.spans
          |> Enum.filter(& &1.bounds)
          |> Enum.sort_by(fn s -> {-(s.bounds.top + s.bounds.bottom), s.bounds.left} end)
          |> group_into_lines()
          |> Enum.map_join("\n", fn line ->
            text =
              line
              |> Enum.sort_by(& &1.bounds.left)
              |> Enum.map(& &1.text)
              |> Enum.join(" ")
              |> String.trim()

            ~s|      <p>#{escape(text)}</p>|
          end)

        # R-16: never silently omit — flag pages without extractable text.
        note =
          if paragraphs == "" do
            "\n      <p class=\"note\">No extractable text on this page — run OCR first.</p>"
          else
            ""
          end

        ~s|    <section class="text-page" data-page="#{tp.page}">\n#{paragraphs}#{note}\n    </section>|
      end)

    {:ok, sections}
  end

  # ── Line grouping ────────────────────────────────────────────────────────

  # Group spans into lines when their vertical ranges overlap within a
  # threshold (half the average line height) — the same grouping the
  # PDF→Office pipeline uses.
  defp group_into_lines([]), do: []

  defp group_into_lines([first | rest]) do
    avg_height = avg_line_height([first | rest])
    threshold = max(avg_height * 0.5, 4.0)
    do_group_lines(rest, [[first]], threshold)
  end

  defp do_group_lines([], groups, _threshold), do: Enum.map(groups, &Enum.reverse/1)

  defp do_group_lines([span | rest], [current | groups], threshold) do
    ref_span = hd(current)
    overlap_y = y_overlap(ref_span, span)

    if overlap_y >= threshold do
      do_group_lines(rest, [[span | current] | groups], threshold)
    else
      do_group_lines(rest, [[span], current | groups], threshold)
    end
  end

  defp y_overlap(a, b) do
    a_top = max(a.bounds.top, b.bounds.top)
    a_bot = min(a.bounds.bottom, b.bounds.bottom)
    max(0.0, a_top - a_bot)
  end

  defp avg_line_height(spans) do
    heights =
      Enum.map(spans, fn s ->
        abs(s.bounds.top - s.bounds.bottom)
      end)

    if heights == [],
      do: 12.0,
      else: Enum.sum(heights) / length(heights)
  end

  # ── Page rendering ───────────────────────────────────────────────────────

  # Render one page at DPI, re-encode PNG → WebP, return a base64 data URI.
  defp render_page_webp(ref, page, index, dpi, webp_quality) do
    with {:ok, png} <- Render.render_page(ref, index, dpi: dpi),
         {:ok, webp} <- png_to_webp(png, webp_quality) do
      {:ok, "data:image/webp;base64,#{Base.encode64(webp)}"}
    end
  end

  defp png_to_webp(png, webp_quality) do
    with {:ok, img} <- Vix.Vips.Image.new_from_buffer(png),
         {:ok, webp} <- Vix.Vips.Image.write_to_buffer(img, ".webp[Q=#{webp_quality}]") do
      {:ok, webp}
    else
      {:error, reason} -> {:error, {:webp_encode, reason}}
    end
  end

  # ── Document shell ───────────────────────────────────────────────────────

  defp build_document(title, mode, body) do
    overlay_css =
      if mode == :overlay do
        ~s|
      .t { user-select: text; cursor: text; }
      ::selection { background: rgba(59,130,246,.35); color: transparent; }|
      else
        ""
      end

    ~s|<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <title>#{escape(title)}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Noto Sans", Helvetica, Arial, sans-serif; background: #525659; padding: 24px 8px; }
    .page { background: #fff; }
    .text-page { max-width: 46rem; margin: 0 auto 1.5rem; padding: 2.5rem; background: #fff; box-shadow: 0 1px 4px rgba(0,0,0,.25); }
    .text-page p { font-size: 12pt; line-height: 1.6; color: #1a1a1a; margin: 0.4em 0; }
    .text-page p:empty { display: none; }
    .text-page p.note { font-style: italic; color: #b45309; font-size: 10pt; }#{overlay_css}
  </style>
</head>
<body>
#{body}
</body>
</html>|
  end

  # ── Escaping ─────────────────────────────────────────────────────────────

  # Escape HTML special characters in text content. The strings we emit are
  # attribute values (span titles) and text content, so both & and < must go.
  defp escape(nil), do: ""

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
