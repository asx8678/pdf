defmodule Quire.EngineWrapperTest do
  use ExUnit.Case, async: false

  # A 1×1 pixel PNG (valid 67-byte binary)
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

  setup do
    orig_adapter = Application.get_env(:quire, :storage_adapter)
    orig_backend = Application.get_env(:quire, :storage_backend)
    orig_data_dir = Application.get_env(:quire, :data_dir)

    Application.put_env(:quire, :storage_adapter, Quire.Storage.Web)
    Application.put_env(:quire, :storage_backend, Quire.Storage.Web.Filesystem)
    tmp_root = Path.join(System.tmp_dir!(), "engine_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_root)
    Application.put_env(:quire, :data_dir, tmp_root)

    on_exit(fn ->
      Application.put_env(:quire, :storage_adapter, orig_adapter)
      Application.put_env(:quire, :storage_backend, orig_backend)
      Application.put_env(:quire, :data_dir, orig_data_dir)
      File.rm_rf!(tmp_root)
    end)

    :ok
  end

  describe "Quire.Render.Pdfium" do
    test "module exists and exports callbacks" do
      assert function_exported?(Quire.Render.Pdfium, :page_count, 1)
      assert function_exported?(Quire.Render.Pdfium, :render_page, 3)
      assert function_exported?(Quire.Render.Pdfium, :thumbnails, 2)
      assert function_exported?(Quire.Render.Pdfium, :extract_text, 2)
      assert function_exported?(Quire.Render.Pdfium, :extract_images, 2)
      assert function_exported?(Quire.Render.Pdfium, :outline, 1)
      assert function_exported?(Quire.Render.Pdfium, :form_fields, 1)
      assert function_exported?(Quire.Render.Pdfium, :annotations, 1)
      assert function_exported?(Quire.Render.Pdfium, :search, 3)
      assert function_exported?(Quire.Render.Pdfium, :page_geometry, 1)
      assert function_exported?(Quire.Render.Pdfium, :save, 2)
      assert function_exported?(Quire.Render.Pdfium, :import_pages, 3)
      assert function_exported?(Quire.Render.Pdfium, :new_document, 1)
      assert function_exported?(Quire.Render.Pdfium, :add_page, 3)
    end

    test "mutation operations work end to end" do
      # new_document creates a 1-page PDF and stores it
      {:ok, ref} = Quire.Render.Pdfium.new_document(format: "A4")
      assert %Quire.Storage.Ref{} = ref

      # The saved document is a valid PDF
      {:ok, pages} = Quire.Render.Pdfium.page_count(ref)
      assert pages >= 1

      # save round-trips through Storage
      {:ok, saved_ref} = Quire.Render.Pdfium.save(ref, [])
      assert %Quire.Storage.Ref{} = saved_ref
      {:ok, saved_count} = Quire.Render.Pdfium.page_count(saved_ref)
      assert saved_count >= 1
    end

    test "handles invalid PDF with error" do
      content = "not a pdf"
      {:ok, ref} = Quire.Storage.put(content, name: "bad.pdf")

      assert {:error, _} = Quire.Render.Pdfium.page_count(ref)
    end

    @tag :skip
    test "page_count returns count for valid PDF" do
      # Needs T-016 corpus fixtures (pdf-5o8)
    end

    @tag :skip
    test "render_page produces PNG for valid page" do
      # Needs T-016 corpus fixtures (pdf-5o8)
    end

    @tag :skip
    test "extract_text extracts text for valid PDF" do
      # Needs T-016 corpus fixtures (pdf-5o8)
    end
  end

  describe "Quire.Ocr.Preprocess" do
    test "preprocess returns binary PNG for valid input" do
      assert {:ok, png} = Quire.Ocr.Preprocess.preprocess(@tiny_png)
      assert is_binary(png)
      assert binary_part(png, 0, 8) == <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
    end

    test "preprocess with custom threshold" do
      assert {:ok, png} = Quire.Ocr.Preprocess.preprocess(@tiny_png, threshold: 200)
      assert is_binary(png)
      assert binary_part(png, 0, 8) == <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
    end

    test "preprocess rejects oversized input" do
      large = :binary.copy(<<0>>, 51 * 1024 * 1024)

      assert {:error, %Quire.Engine.Error{code: :invalid_argument}} =
               Quire.Ocr.Preprocess.preprocess(large)
    end

    test "preprocess rejects invalid image bytes" do
      assert {:error, %Quire.Engine.Error{}} = Quire.Ocr.Preprocess.preprocess(<<"not an image">>)
    end

    test "info returns metadata for valid image" do
      assert {:ok, meta} = Quire.Ocr.Preprocess.info(@tiny_png)
      assert meta.width == 1
      assert meta.height == 1
      assert is_integer(meta.bands)
      assert is_atom(meta.format)
    end

    test "info errors on invalid image" do
      assert {:error, %Quire.Engine.Error{}} = Quire.Ocr.Preprocess.info(<<"not an image">>)
    end
  end

  describe "Quire.Ocr.Tesseract" do
    @tag :skip
    test "run/2 is unavailable when image_ocr is not loaded" do
      # Skip — see pdf-tuj ADR on vendored-vs-Homebrew Tesseract
      assert {:error, %Quire.Engine.Error{code: :unavailable}} =
               Quire.Ocr.Tesseract.run(@tiny_png, [])
    end

    @tag :skip
    test "versions/0 returns unknown when dep missing" do
      assert Quire.Ocr.Tesseract.versions() == %{tesseract: "unknown", leptonica: "unknown"}
    end
  end

  describe "Quire.Compose.Primitives" do
    test "text_object produces BT ET Tm operators" do
      assert {:ok, iodata} = Quire.Compose.Primitives.text_object("Hello", 100, 200)
      result = IO.iodata_to_binary(iodata)
      assert result =~ "BT"
      assert result =~ "ET"
      assert result =~ "Tm"
      assert result =~ "Tj"
    end

    test "text_object with custom font" do
      assert {:ok, iodata} =
               Quire.Compose.Primitives.text_object("Hello", 100, 200,
                 font: "Helvetica",
                 font_size: 12
               )

      result = IO.iodata_to_binary(iodata)
      assert result =~ "Helvetica"
    end

    test "rectangle produces re operator" do
      assert {:ok, iodata} = Quire.Compose.Primitives.rectangle(50, 50, 200, 100, fill: true)
      result = IO.iodata_to_binary(iodata)
      assert result =~ "re"
    end

    test "line produces m l S operators" do
      assert {:ok, iodata} = Quire.Compose.Primitives.line(0, 0, 100, 100)
      result = IO.iodata_to_binary(iodata)
      assert result =~ "m"
      assert result =~ "l"
      assert result =~ "S"
    end

    test "image_placement produces cm and Do" do
      assert {:ok, iodata} = Quire.Compose.Primitives.image_placement("Im0", 0, 0, 100, 100)
      result = IO.iodata_to_binary(iodata)
      assert result =~ "cm"
      assert result =~ "Do"
    end

    test "appearance_stream for checkbox" do
      assert {:ok, iodata} =
               Quire.Compose.Primitives.appearance_stream(:checkbox, true, w: 12, h: 12)

      result = IO.iodata_to_binary(iodata)
      assert result =~ "q"
      assert result =~ "Q"
    end

    test "appearance_stream for text field" do
      assert {:ok, iodata} =
               Quire.Compose.Primitives.appearance_stream(:text, "value", w: 100, h: 20)

      result = IO.iodata_to_binary(iodata)
      assert result =~ "BT"
      assert result =~ "ET"
    end

    test "compose joins operator iodata" do
      {:ok, r} = Quire.Compose.Primitives.rectangle(50, 50, 200, 100, fill: true)
      {:ok, t} = Quire.Compose.Primitives.text_object("Hi", 100, 200)

      assert {:ok, combined} = Quire.Compose.Primitives.compose([r, t])
      result = IO.iodata_to_binary(combined)
      assert result =~ "re"
      assert result =~ "BT"
      assert result =~ "ET"
    end

    test "rejects negative dimensions" do
      assert {:error, %Quire.Engine.Error{code: :invalid_argument}} =
               Quire.Compose.Primitives.rectangle(50, 50, -10, 100)
    end
  end
end
