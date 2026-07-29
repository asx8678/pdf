defmodule Quire.Render.PdfiumTest do
  use ExUnit.Case, async: true

  setup do
    pdf_path = Path.expand("../../fixtures/pdfs/simple_text.pdf", __DIR__)
    {:ok, pdf_bytes} = File.read(pdf_path)
    {:ok, ref} = Quire.Storage.put(pdf_bytes, name: "test.pdf")
    %{ref: ref, bytes: pdf_bytes}
  end

  test "page_count returns correct count", %{ref: ref} do
    assert {:ok, 1} = Quire.Render.Pdfium.page_count(ref)
  end

  test "page_geometry returns dimensions with rotation", %{ref: ref} do
    {:ok, pages} = Quire.Render.Pdfium.page_geometry(ref)
    assert length(pages) == 1
    page = hd(pages)
    assert is_integer(page.width)
    assert is_integer(page.height)
    assert is_integer(page.rotate)
    assert page.rotate == 0
  end

  test "render_page produces PNG", %{ref: ref} do
    {:ok, png} = Quire.Render.Pdfium.render_page(ref, 0, dpi: 72)
    assert is_binary(png)
    assert binary_part(png, 0, 4) == <<137, 80, 78, 71>>
  end

  test "new_document creates PDF with one page", %{ref: _ref} do
    {:ok, new_ref} = Quire.Render.Pdfium.new_document(format: "Letter")
    assert {:ok, 1} = Quire.Render.Pdfium.page_count(new_ref)
  end

  test "outline returns empty for simple document", %{ref: ref} do
    assert {:ok, []} = Quire.Render.Pdfium.outline(ref)
  end

  test "extract_text returns text content", %{ref: ref} do
    {:ok, pages} = Quire.Render.Pdfium.extract_text(ref, [])
    assert length(pages) > 0
    page = hd(pages)
    assert page.page == 0
    assert is_list(page.spans)
  end

  test "extract_text returns span-level bounds", %{ref: ref} do
    {:ok, pages} = Quire.Render.Pdfium.extract_text(ref, [])
    page = hd(pages)
    assert length(page.spans) > 0
    span = hd(page.spans)
    assert is_binary(span.text)
    assert is_map(span.bounds)
    assert Map.has_key?(span.bounds, :left)
    assert Map.has_key?(span.bounds, :bottom)
    assert Map.has_key?(span.bounds, :right)
    assert Map.has_key?(span.bounds, :top)
  end

  test "form_fields returns empty list", %{ref: ref} do
    assert {:ok, []} = Quire.Render.Pdfium.form_fields(ref)
  end

  test "annotations returns empty list", %{ref: ref} do
    assert {:ok, []} = Quire.Render.Pdfium.annotations(ref)
  end

  test "search returns results", %{ref: ref} do
    {:ok, results} = Quire.Render.Pdfium.search(ref, "Hello", [])
    assert length(results) > 0
    result = hd(results)
    assert Map.has_key?(result, :page)
    assert Map.has_key?(result, :text)
    assert Map.has_key?(result, :rects)
  end

  test "save returns a ref", %{ref: ref} do
    {:ok, saved_ref} = Quire.Render.Pdfium.save(ref, [])
    assert %Quire.Storage.Ref{} = saved_ref
    {:ok, bytes} = Quire.Storage.get(saved_ref)
    assert byte_size(bytes) > 0
  end

  test "new_document then save round-trips", %{ref: _ref} do
    {:ok, new_ref} = Quire.Render.Pdfium.new_document(format: "A4")
    {:ok, saved_ref} = Quire.Render.Pdfium.save(new_ref, [])
    assert %Quire.Storage.Ref{} = saved_ref
    {:ok, 1} = Quire.Render.Pdfium.page_count(saved_ref)
  end

  test "thumbnails returns PNGs", %{ref: ref} do
    {:ok, pngs} = Quire.Render.Pdfium.thumbnails(ref, pages: [0], max_dimension: 128)
    assert length(pngs) == 1
    png = hd(pngs)
    assert is_binary(png)
    assert binary_part(png, 0, 4) == <<137, 80, 78, 71>>
  end

  test "add_page adds a page", %{ref: ref} do
    {:ok, new_ref} = Quire.Render.Pdfium.add_page(ref, :letter, page: 0)
    assert %Quire.Storage.Ref{} = new_ref
    {:ok, count} = Quire.Render.Pdfium.page_count(new_ref)
    assert count >= 1
  end

  test "extract_images returns list of refs", %{ref: ref} do
    {:ok, image_refs} = Quire.Render.Pdfium.extract_images(ref, [])
    assert is_list(image_refs)
  end

  test "import_pages works with same doc source and dest", %{ref: ref} do
    {:ok, imported_ref} = Quire.Render.Pdfium.import_pages(ref, ref, [0])
    assert %Quire.Storage.Ref{} = imported_ref
    {:ok, count} = Quire.Render.Pdfium.page_count(imported_ref)
    assert count >= 1
  end
end
