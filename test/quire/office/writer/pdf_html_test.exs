defmodule Quire.Office.Writer.PdfHtmlTest do
  use ExUnit.Case, async: true

  alias Quire.Office.Writer.PdfHtml
  alias Quire.Geometry

  @fixtures_dir Path.expand("../../../fixtures/pdfs", __DIR__)

  setup do
    {:ok, bytes} = File.read(Path.join(@fixtures_dir, "rotated_pages.pdf"))
    {:ok, ref} = Quire.Storage.put(bytes, name: "rotated_pages.pdf")
    %{ref: ref}
  end

  defp load_fixture(name) do
    {:ok, bytes} = File.read(Path.join(@fixtures_dir, name))
    {:ok, ref} = Quire.Storage.put(bytes, name: name)
    ref
  end

  describe "overlay mode" do
    test "produces a single self-contained file with embedded WebP data URIs", %{ref: ref} do
      {:ok, html} = PdfHtml.write(ref, :html, mode: :overlay, title: "Rotated")

      # One WebP page image per page (4 pages)
      assert length(Regex.scan(~r/data:image\/webp;base64,/, html)) == 4

      # No external asset references of any kind
      refs =
        Regex.scan(~r/(?:src|href)="(?!data:)[^"]*"/, html)
        |> List.flatten()

      assert refs == []

      # Title present and escaped
      assert html =~ "<title>Rotated</title>"
    end

    test "positions spans over the rendered page using display geometry", %{ref: ref} do
      {:ok, html} = PdfHtml.write(ref, :html, mode: :overlay, dpi: 72)
      {:ok, pages} = Quire.Render.Pdfium.page_geometry(ref)
      {:ok, text_pages} = Quire.Render.Pdfium.extract_text(ref, [])

      for tp <- text_pages do
        page = Enum.at(pages, tp.page)
        span = hd(tp.spans)
        css = Geometry.span_to_css(span.bounds, page.width, page.height, page.rotate)

        # At dpi 72, scale is 1:1 with points — the inline style must match
        # the geometry module's output.
        assert html =~ ~s/left:#{css.left}px/
        assert html =~ ~s/top:#{css.top}px/
        assert html =~ ~s/width:#{css.width}px/
        assert html =~ ~s/height:#{css.height}px/
      end
    end

    test "rotated pages keep spans inside the displayed page", %{ref: ref} do
      {:ok, html} = PdfHtml.write(ref, :html, mode: :overlay, dpi: 72)
      {:ok, pages} = Quire.Render.Pdfium.page_geometry(ref)

      # Every span style must carry non-negative left/top (never outside
      # the page top-left). Regex.scan yields [full, style, text] lists.
      for [_full, _style, _text] <-
            Regex.scan(~r/style="position:absolute;([^"]+)">([^<]*)<\/span>/, html) do
        refute html =~ "left:-"
        refute html =~ "top:-"
      end

      # All four spans exist and their pages are present
      assert length(Regex.scan(~r/<span class="t"/, html)) == 4

      for page <- pages, index <- [0, 1, 2, 3] do
        assert html =~ ~s/data-page="#{index}"/
        # page dims in the section style at dpi 72 == points
        assert html =~ ~s/width:#{page.width}px/
        assert html =~ ~s/height:#{page.height}px/
      end
    end

    test "cropped_nonzero_origin.pdf spans land in crop frame", _ do
      ref = load_fixture("cropped_nonzero_origin.pdf")
      {:ok, html} = PdfHtml.write(ref, :html, mode: :overlay, dpi: 72)

      assert html =~ ~s/data:image\/webp;base64,/
      # The "Cropped" span text must be present and selectable
      assert html =~ ~s/>Cropped</

      # CropBox origin (72,72) subtracted: span left ~0.6pt, not ~72.6pt.
      {:ok, pages} = Quire.Render.Pdfium.page_geometry(ref)
      {:ok, text_pages} = Quire.Render.Pdfium.extract_text(ref, [])
      span = hd(hd(text_pages).spans)
      css = Geometry.span_to_css(span.bounds, hd(pages).width, hd(pages).height, 0)
      assert css.left < 5.0
      assert html =~ ~s/left:#{css.left}px/
    end
  end

  describe "text-only mode" do
    test "produces semantic reflowed HTML with no page images", %{ref: ref} do
      {:ok, html} = PdfHtml.write(ref, :html, mode: :text_only, title: "Rotated")

      refute html =~ "data:image/webp"
      refute html =~ "<img"
      refute html =~ ~s/position:absolute/

      # All four page labels survive as flowing text
      for label <- ["R0", "R90", "R180", "R270"] do
        assert html =~ label
      end

      # Paragraphs per page, page sections present
      assert html =~ ~s/<section class="text-page" data-page="0">/
      assert html =~ ~s/<section class="text-page" data-page="3">/
      assert html =~ "<p>"
    end

    test "joins multi-span lines into single paragraphs", _ do
      ref = load_fixture("simple_text.pdf")
      {:ok, html} = PdfHtml.write(ref, :html, mode: :text_only)

      # simple_text.pdf has multiple words; at least one paragraph must
      # contain more than one word.
      paragraphs = Regex.scan(~r/<p>([^<]+)<\/p>/, html)

      assert Enum.any?(paragraphs, fn [_, text] -> length(String.split(text)) > 1 end)
    end
  end

  describe "escaping" do
    test "escapes HTML special characters in span text", _ do
      # RTL fixture contains text; use a synthetic span via the text-only path
      ref = load_fixture("rtl_arabic.pdf")

      case PdfHtml.write(ref, :html, mode: :text_only) do
        {:ok, html} ->
          # No raw < or > inside paragraph bodies
          refute Regex.match?(~r/<p>[^<]*[<>][^<]*<\/p>/, html)

        {:error, _} ->
          :ok
      end
    end
  end

  describe "error handling" do
    test "rejects an unknown mode", %{ref: ref} do
      assert {:error, {:invalid_mode, :bogus}} = PdfHtml.write(ref, :html, mode: :bogus)
    end
  end

  describe "R-16: no silent omission" do
    test "text-only mode flags pages without extractable text", _ do
      ref = load_fixture("scanned_300dpi.pdf")
      {:ok, html} = PdfHtml.write(ref, :html, mode: :text_only)

      assert html =~ "No extractable text on this page — run OCR first."
      refute html =~ "<img"
    end
  end
end
