defmodule Quire.Ocr.TesseractTest do
  use ExUnit.Case, async: true

  describe "check/0" do
    test "returns ok when image_ocr is available" do
      assert Quire.Ocr.Tesseract.check() == :ok
    end
  end

  describe "versions/0" do
    test "returns a map with tesseract and leptonica keys" do
      v = Quire.Ocr.Tesseract.versions()
      assert is_map(v)
      assert Map.has_key?(v, :tesseract)
      assert Map.has_key?(v, :leptonica)
    end
  end

  describe "run/2" do
    @tiny_png <<
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x02,
      0x00,
      0x00,
      0x00,
      0x90,
      0x77,
      0x53,
      0xDE,
      0x00,
      0x00,
      0x00,
      0x0C,
      0x49,
      0x44,
      0x41,
      0x54,
      0x08,
      0xD7,
      0x63,
      0x60,
      0x60,
      0x60,
      0x00,
      0x00,
      0x00,
      0x04,
      0x00,
      0x01,
      0x27,
      0x34,
      0x27,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82
    >>

    test "run returns ok or error tuple" do
      result = Quire.Ocr.Tesseract.run(@tiny_png, language: "eng")

      assert match?({:ok, list} when is_list(list), result) or
               match?({:error, %Quire.Engine.Error{}}, result)
    end

    test "rejects oversized input" do
      large = :binary.copy(<<0>>, 51 * 1024 * 1024)

      assert {:error, %Quire.Engine.Error{code: :invalid_argument}} =
               Quire.Ocr.Tesseract.run(large, [])
    end
  end
end
