defmodule Quire.Forms.DetectTest do
  use ExUnit.Case, async: true

  alias Quire.Forms.Detect

  # Pure raster unit tests: hand-built RGBA bitmaps at dpi 72 (1 px = 1 pt)
  # so detected rects are directly comparable to the drawn geometry.

  @w 200
  @h 200

  defp blank_bitmap(w \\ @w, h \\ @h) do
    %ExPdfium.Bitmap{
      data: :binary.copy(<<255, 255, 255, 255>>, w * h),
      width: w,
      height: h,
      stride: w * 4,
      format: :rgba
    }
  end

  defp ink(%ExPdfium.Bitmap{} = bmp, x, y) do
    off = (y * bmp.width + x) * 4
    data = bmp.data

    %{bmp | data: binary_part(data, 0, off) <> <<0, 0, 0, 255>> <> binary_part(data, off + 4, byte_size(data) - off - 4)}
  end

  defp stroke(bmp, x0, y0, x1, y1) do
    for x <- x0..x1, y <- y0..y1, reduce: bmp do
      acc -> ink(acc, x, y)
    end
  end

  # Four 1px strokes forming a hollow rectangle (like a printed form box).
  defp box_outline(bmp, x0, y0, x1, y1) do
    bmp
    |> stroke(x0, y0, x1, y0)
    |> stroke(x0, y1, x1, y1)
    |> stroke(x0, y0, x0, y1)
    |> stroke(x1, y0, x1, y1)
  end

  defp info(rotation \\ 0, w \\ @w, h \\ @h) do
    %{
      width: w,
      height: h,
      rotation: rotation,
      label: nil,
      boxes: %{media: %{left: 0, bottom: 0, right: w, top: h}}
    }
  end

  describe "detect_page/4" do
    test "blank page yields no fields" do
      assert Detect.detect_page(blank_bitmap(), info(), 0, dpi: 72) == []
    end

    test "hollow box becomes a text field in user space" do
      bmp = blank_bitmap() |> box_outline(60, 40, 120, 80)
      [field] = Detect.detect_page(bmp, info(), 0, dpi: 72)

      assert field.kind == :text
      assert field.page_index == 0
      assert_rect field.rect, [60, 120, 120, 160]
    end

    test "small hollow square becomes a checkbox" do
      bmp = blank_bitmap() |> box_outline(60, 100, 84, 124)
      [field] = Detect.detect_page(bmp, info(), 0, dpi: 72)

      assert field.kind == :checkbox
      assert_rect field.rect, [60, 76, 84, 100]
    end

    test "standalone long horizontal line becomes an underline text field" do
      bmp = blank_bitmap() |> stroke(40, 150, 160, 150)
      [field] = Detect.detect_page(bmp, info(), 0, dpi: 72)

      assert field.kind == :text
      # 30px detection band above the line (dpi 72 → 30pt)
      assert_rect field.rect, [40, 49, 160, 80]
    end

    test "nested boxes are deduped to the largest" do
      bmp =
        blank_bitmap()
        |> box_outline(50, 50, 150, 110)
        |> box_outline(70, 65, 110, 90)

      fields = Detect.detect_page(bmp, info(), 0, dpi: 72)

      assert length(fields) == 1
      assert_rect hd(fields).rect, [50, 90, 150, 150]
    end

    test "90-degree rotated page maps rects back to content space" do
      # Unrotated content is 100×200; display bitmap is the rotated 200×100.
      bmp = blank_bitmap(200, 100) |> box_outline(60, 20, 120, 40)
      info = info(90, 100, 200)
      [field] = Detect.detect_page(bmp, info, 0, dpi: 72)

      assert field.kind == :text
      assert_rect field.rect, [20, 60, 40, 120]
    end
  end

  defp assert_rect(rect, expected) do
    assert length(rect) == 4

    Enum.zip(rect, expected)
    |> Enum.each(fn {got, want} -> assert_in_delta(got, want, 1.0) end)
  end
end
