defmodule Quire.GeometryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quire.Geometry

  property "CSS -> PDF -> CSS round-trip is identity within 0.01 pt" do
    check all(
            page_w <- StreamData.integer(100..1200),
            page_h <- StreamData.integer(100..1600),
            x <- StreamData.integer(0..max(0, page_w - 10)),
            y <- StreamData.integer(0..max(0, page_h - 10)),
            w <- StreamData.integer(10..max(10, page_w - x)),
            h <- StreamData.integer(10..max(10, page_h - y))
          ) do
      assert Geometry.round_trip_ok?(x, y, w, h, page_w, page_h)
    end
  end

  property "apply_rotation 0 deg is identity" do
    check all(
            x <- StreamData.integer(0..1000),
            y <- StreamData.integer(0..1000),
            w <- StreamData.integer(100..1200),
            h <- StreamData.integer(100..1600)
          ) do
      assert {^x, ^y} = Geometry.apply_rotation(x, y, w, h, 0)
    end
  end

  test "rotation 90 deg swaps axes" do
    assert {100, 350} = Geometry.apply_rotation(50, 100, 400, 600, 90)
  end

  test "rotation 180 deg flips both axes" do
    assert {350, 500} = Geometry.apply_rotation(50, 100, 400, 600, 180)
  end

  test "rotation 270 deg reverse swaps axes" do
    assert {500, 50} = Geometry.apply_rotation(50, 100, 400, 600, 270)
  end

  test "crop origin subtraction" do
    assert {60, 70} = Geometry.subtract_crop_origin(10, 20, 50, 50)
    assert {10, 20} = Geometry.subtract_crop_origin(60, 70, -50, -50)
  end

  test "crop origin addition (inverse)" do
    assert {10, 20} = Geometry.add_crop_origin(60, 70, 50, 50)
  end
end
