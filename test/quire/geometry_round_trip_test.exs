defmodule Quire.GeometryRoundTripTest do
  use ExUnit.Case, async: true

  alias Quire.Geometry

  @fixtures_dir Path.expand("../fixtures/pdfs", __DIR__)

  describe "cropped_nonzero_origin.pdf" do
    setup :load_cropped

    test "page geometry reports CropBox dimensions", %{ref: ref} do
      {:ok, pages} = Quire.Render.Pdfium.page_geometry(ref)
      assert length(pages) == 1

      page = hd(pages)
      # CropBox = [72, 72, 540, 720] → 468 x 648
      # MediaBox = [0, 0, 612, 792] → 612 x 792
      assert page.width == 468
      assert page.height == 648
    end

    test "text coordinates are in CropBox frame (subtract origin)", %{ref: ref} do
      {:ok, pages} = Quire.Render.Pdfium.extract_text(ref, [])
      assert length(pages) > 0

      page = hd(pages)
      assert length(page.spans) > 0

      span = hd(page.spans)
      assert span.text == "Cropped"

      # CropBox origin is (72, 72). MediaBox origin is (0, 0).
      # Coordinates from PDFium are in CropBox frame.
      # subtract_crop_origin = add origin to shift to MediaBox frame.
      crop_origin_x = 72
      crop_origin_y = 72

      {mx, my} =
        Geometry.subtract_crop_origin(
          span.bounds.left,
          span.bounds.bottom,
          crop_origin_x,
          crop_origin_y
        )

      # In MediaBox frame, the text should exceed the CropBox origin
      assert mx > 72
      assert my > -1_000  # bottom can be negative in CropBox frame

      # Round trip: back to CropBox frame
      {cx, cy} = Geometry.add_crop_origin(mx, my, crop_origin_x, crop_origin_y)
      assert abs(cx - span.bounds.left) < 0.01
      assert abs(cy - span.bounds.bottom) < 0.01
    end
  end

  describe "rotated_pages.pdf" do
    setup :load_rotated

    test "page geometry reports rotation values", %{ref: ref} do
      {:ok, pages} = Quire.Render.Pdfium.page_geometry(ref)
      assert length(pages) == 4

      assert %{rotate: 0} = Enum.at(pages, 0)
      assert %{rotate: 90} = Enum.at(pages, 1)
      assert %{rotate: 180} = Enum.at(pages, 2)
      assert %{rotate: 270} = Enum.at(pages, 3)
    end

    test "apply_rotation matches expected formulas", %{ref: ref} do
      {:ok, pages} = Quire.Render.Pdfium.page_geometry(ref)
      %{width: w, height: h} = Enum.at(pages, 0)

      assert Geometry.apply_rotation(10, 20, w, h, 0) == {10, 20}
      assert Geometry.apply_rotation(10, 20, w, h, 90) == {20, w - 10}
      assert Geometry.apply_rotation(10, 20, w, h, 180) == {w - 10, h - 20}
      assert Geometry.apply_rotation(10, 20, w, h, 270) == {h - 20, 10}
    end

    test "CSS -> PDF -> CSS round trip is identity for all rotations", %{ref: ref} do
      {:ok, pages} = Quire.Render.Pdfium.page_geometry(ref)

      for page <- pages do
        rot = page.rotate
        pw_pdf = page.width
        ph_pdf = page.height

        # The CSS viewport dimensions swap for 90/270 rotation
        css_h = if rot in [90, 270], do: pw_pdf, else: ph_pdf
        css_w = if rot in [90, 270], do: ph_pdf, else: pw_pdf

        positions = [
          {0, 0, 50, 50},
          {10, 20, 100, 50},
          {max(0, css_w - 60), max(0, css_h - 60), 50, 50},
          {div(css_w, 2), div(css_h, 2), 30, 30}
        ]

        for {x, y, bw, bh} <- positions do
          assert Geometry.round_trip_ok?(x, y, bw, bh, css_h, rot, pw_pdf),
                 "Round trip failed at (#{x}, #{y}) size #{bw}x#{bh} rotation #{rot} on CSS #{css_w}x#{css_h} PDF #{pw_pdf}x#{ph_pdf}"
        end
      end
    end
  end

  defp load_fixture(name) do
    path = Path.join(@fixtures_dir, name)
    {:ok, bytes} = File.read(path)
    {:ok, ref} = Quire.Storage.put(bytes, name: name)
    %{ref: ref}
  end

  defp load_cropped(_), do: load_fixture("cropped_nonzero_origin.pdf")
  defp load_rotated(_), do: load_fixture("rotated_pages.pdf")
end
