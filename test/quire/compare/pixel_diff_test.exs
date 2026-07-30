defmodule Quire.Compare.PixelDiffTest do
  use ExUnit.Case, async: true

  alias Quire.Compare.PixelDiff
  alias Quire.Compare.PixelDiff.PagePixelDiff

  # Helper to build a synthetic Bitmap struct
  defp make_bitmap(data, w, h) do
    %ExPdfium.Bitmap{data: data, width: w, height: h, stride: w * 3, format: :bgr}
  end

  describe "compute_diff/2" do
    test "identical bitmaps produce no diff" do
      data = <<100, 150, 200, 100, 150, 200, 100, 150, 200>>
      a = make_bitmap(data, 3, 1)
      b = make_bitmap(data, 3, 1)

      diff = PixelDiff.compute_diff(a, b)
      assert byte_size(diff) == 3
      assert diff == <<0, 0, 0>>
    end

    test "different bitmaps show diff pixels" do
      a_data = <<100, 150, 200, 100, 150, 200, 100, 150, 200>>
      # Make center pixel different (red component changes by >10)
      b_data = <<100, 150, 200, 200, 150, 200, 100, 150, 200>>
      a = make_bitmap(a_data, 3, 1)
      b = make_bitmap(b_data, 3, 1)

      diff = PixelDiff.compute_diff(a, b)
      # Middle pixel should show as changed (255), others unchanged (0)
      assert diff == <<0, 255, 0>>
    end

    test "treats dimension mismatch as all different" do
      a = make_bitmap(<<100, 150, 200>>, 1, 1)
      b = make_bitmap(<<100, 150, 200, 100, 150, 200>>, 2, 1)

      diff = PixelDiff.compute_diff(a, b)
      assert byte_size(diff) == 3
      assert diff == <<255, 255, 255>>
    end
  end

  describe "diff_ratio/1" do
    test "identical images have ratio 0.0" do
      result = %PixelDiff{total_diff_pixels: 0, total_pixels: 100, pages: []}
      assert PixelDiff.diff_ratio(result) == 0.0
    end

    test "half-different images have ratio 0.5" do
      result = %PixelDiff{total_diff_pixels: 50, total_pixels: 100, pages: []}
      assert PixelDiff.diff_ratio(result) == 0.5
    end

    test "no pixels returns 0.0" do
      result = %PixelDiff{total_diff_pixels: 0, total_pixels: 0, pages: []}
      assert PixelDiff.diff_ratio(result) == 0.0
    end
  end

  describe "find_changed_regions/2" do
    test "no changes returns empty list" do
      diff_map = <<0, 0, 0, 0, 0, 0, 0, 0, 0>>
      assert PixelDiff.find_changed_regions(diff_map, 3) == []
    end

    test "single changed pixel produces one region" do
      # 3x3 grid, center pixel changed
      diff_map = <<0, 0, 0, 0, 255, 0, 0, 0, 0>>
      regions = PixelDiff.find_changed_regions(diff_map, 3)
      assert length(regions) == 1
      region = hd(regions)
      assert region.x == 1
      assert region.y == 1
      assert region.width >= 1
      assert region.height >= 1
    end

    test "nil diff map returns empty list" do
      assert PixelDiff.find_changed_regions(nil, 100) == []
    end
  end

  describe "PagePixelDiff struct" do
    test "can create and access fields" do
      diff = %PagePixelDiff{
        page_a: 0,
        page_b: 1,
        diff_pixels: 42,
        total_pixels: 1000,
        diff_map: <<1, 2, 3>>,
        changed_regions: [%{x: 0, y: 0, width: 10, height: 10}]
      }

      assert diff.page_a == 0
      assert diff.page_b == 1
      assert diff.diff_pixels == 42
    end
  end
end
