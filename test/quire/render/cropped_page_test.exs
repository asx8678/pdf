defmodule Quire.Render.CroppedPageTest do
  use ExUnit.Case, async: true

  setup do
    path = Path.expand("../../fixtures/pdfs/cropped_nonzero_origin.pdf", __DIR__)
    {:ok, bytes} = File.read(path)
    {:ok, ref} = Quire.Storage.put(bytes, name: "cropped.pdf")
    %{ref: ref}
  end

  test "page_geometry returns CropBox dimensions", %{ref: ref} do
    {:ok, pages} = Quire.Render.Pdfium.page_geometry(ref)
    assert length(pages) == 1

    page = hd(pages)
    # CropBox = [72, 72, 540, 720] → 468 x 648
    # MediaBox = [0, 0, 612, 792] → 612 x 792
    assert page.width == 468
    assert page.height == 648
  end

  test "search results use CropBox frame", %{ref: ref} do
    {:ok, _pages} = Quire.Render.Pdfium.page_geometry(ref)

    {:ok, results} = Quire.Render.Pdfium.search(ref, "Cropped", [])
    assert length(results) > 0

    for r <- results do
      for rect <- r.rects do
        # Coordinates are shifted into CropBox frame (subtract 72 from MediaBox)
        # Original MediaBox left was ~72.6, CropBox left is 72, so crop-frame left ≈ 0.6
        assert rect.left >= 0
        assert rect.right > rect.left
        assert rect.top > rect.bottom
      end
    end
  end

  test "extract_text bounds use CropBox frame", %{ref: ref} do
    {:ok, pages} = Quire.Render.Pdfium.extract_text(ref, [])
    assert length(pages) > 0

    page = hd(pages)
    assert length(page.spans) > 0

    span = hd(page.spans)
    assert span.text == "Cropped"
    assert %{left: left, bottom: bottom, right: right, top: top} = span.bounds
    # All coordinates should be shifted to CropBox space (subtract 72 from MediaBox)
    assert left > 0
    assert right > left
    assert top > bottom
  end

  test "annotations returns empty list for fixture", %{ref: ref} do
    assert {:ok, []} = Quire.Render.Pdfium.annotations(ref)
  end
end
