defmodule Quire.Ocr.PreprocessTest do
  use ExUnit.Case, async: true

  @tiny_png <<
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    0,
    0,
    0,
    13,
    73,
    72,
    68,
    82,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
    8,
    2,
    0,
    0,
    0,
    144,
    119,
    83,
    222,
    0,
    0,
    0,
    12,
    73,
    68,
    65,
    84,
    8,
    215,
    99,
    248,
    207,
    192,
    0,
    0,
    0,
    4,
    0,
    1,
    44,
    98,
    105,
    0,
    0,
    0,
    0,
    73,
    69,
    78,
    68,
    174,
    66,
    96,
    130
  >>

  describe "preprocess/2" do
    test "returns ok with png binary for valid input" do
      assert {:ok, png} = Quire.Ocr.Preprocess.preprocess(@tiny_png)
      assert is_binary(png)
      # Validates PNG header
      assert binary_part(png, 0, 8) == <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
    end

    test "works with custom threshold option" do
      assert {:ok, png} = Quire.Ocr.Preprocess.preprocess(@tiny_png, threshold: 200)
      assert is_binary(png)
    end

    test "rejects oversized input" do
      large = :binary.copy(<<0>>, 51 * 1024 * 1024)

      assert {:error, %Quire.Engine.Error{code: :invalid_argument}} =
               Quire.Ocr.Preprocess.preprocess(large)
    end

    test "rejects invalid image bytes" do
      assert {:error, %Quire.Engine.Error{}} = Quire.Ocr.Preprocess.preprocess(<<"not an image">>)
    end
  end

  describe "info/1" do
    test "returns metadata for valid image" do
      assert {:ok, meta} = Quire.Ocr.Preprocess.info(@tiny_png)
      assert meta.width == 1
      assert meta.height == 1
      assert is_integer(meta.bands)
      assert is_atom(meta.format)
    end

    test "errors on invalid image bytes" do
      assert {:error, %Quire.Engine.Error{}} = Quire.Ocr.Preprocess.info(<<"not an image">>)
    end
  end
end
