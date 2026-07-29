defmodule Quire.InputCapsTest do
  use ExUnit.Case, async: true

  @mb 1024 * 1024

  # ── Render.Pdfium: 500 MB cap ──────────────────────────────────────────

  describe "Quire.Render.Pdfium input cap" do
    test "rejects files larger than 500 MB" do
      large = :binary.copy(<<0>>, 501 * @mb)
      {:ok, ref} = Quire.Storage.put(large, name: "oversized.pdf")

      assert {:error, %Quire.Engine.Error{code: :invalid_argument}} =
               Quire.Render.Pdfium.page_count(ref)

      assert {:error, %Quire.Engine.Error{code: :invalid_argument}} =
               Quire.Render.Pdfium.page_geometry(ref)

      assert {:error, %Quire.Engine.Error{code: :invalid_argument}} =
               Quire.Render.Pdfium.render_page(ref, 0, [])
    end

    test "allows files just under 500 MB" do
      ok_size = 499 * @mb
      bytes = :binary.copy(<<0>>, ok_size)
      {:ok, ref} = Quire.Storage.put(bytes, name: "just_under.pdf")

      # Should pass the size check (but fail to open as PDF — that's fine,
      # the important thing is it reaches open_blob without :invalid_argument)
      result = Quire.Render.Pdfium.page_count(ref)
      refute match?({:error, %Quire.Engine.Error{code: :invalid_argument}}, result)
    end
  end

  # ── Ocr.Tesseract: 50 MB cap ───────────────────────────────────────────

  describe "Quire.Ocr.Tesseract input cap" do
    test "rejects images larger than 50 MB" do
      large = :binary.copy(<<0>>, 51 * @mb)

      assert {:error, %Quire.Engine.Error{code: :invalid_argument}} =
               Quire.Ocr.Tesseract.run(large, [])
    end

    test "allows images just under 50 MB" do
      ok_size = (50 * @mb) - 1
      bytes = :binary.copy(<<0>>, ok_size)

      # Should pass size check but fail on actual image decode
      result = Quire.Ocr.Tesseract.run(bytes, [])
      refute match?({:error, %Quire.Engine.Error{code: :invalid_argument}}, result)
    end
  end

  # ── Ocr.Preprocess: 50 MB + 10 000 px caps ─────────────────────────────

  describe "Quire.Ocr.Preprocess input size cap" do
    test "rejects images larger than 50 MB" do
      large = :binary.copy(<<0>>, 51 * @mb)

      assert {:error, %Quire.Engine.Error{code: :invalid_argument}} =
               Quire.Ocr.Preprocess.preprocess(large)
    end
  end

  describe "Quire.Ocr.Preprocess dimension cap" do
    test "rejects images wider than 10 000 px" do
      path = Path.expand("../fixtures/images/huge_dimensions.png", __DIR__)
      {:ok, bytes} = File.read(path)

      assert {:error, %Quire.Engine.Error{code: :invalid_argument}} =
               Quire.Ocr.Preprocess.preprocess(bytes)
    end

    test "accepts images under 10 000 px per side" do
      path = Path.expand("../fixtures/images/white_1x1.png", __DIR__)
      {:ok, bytes} = File.read(path)

      assert {:ok, _png} = Quire.Ocr.Preprocess.preprocess(bytes)
    end
  end
end
