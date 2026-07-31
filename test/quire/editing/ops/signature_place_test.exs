defmodule Quire.Editing.Ops.SignaturePlaceTest do
  use ExUnit.Case, async: true

  alias Quire.Editing.Ops.SignaturePlace

  @fixture_dir Path.expand("../../../fixtures/pdfs", __DIR__)

  setup do
    {:ok, doc} = ExPdfium.open(File.read!(Path.join(@fixture_dir, "simple_text.pdf")))
    {:ok, pdf} = ExPdfium.save_to_bytes(doc)
    png = File.read!(Path.expand("../../../fixtures/images/transparent.png", __DIR__))
    %{pdf: pdf, png: png}
  end

  describe "apply/2" do
    test "embeds the signature and returns the new bytes", %{pdf: pdf, png: png} do
      op_data = %{pdf_bytes: pdf, page_index: 0, rect: [72.0, 72.0, 200.0, 100.0], png: png}

      assert {:ok, embedded} = SignaturePlace.apply(op_data, %{})
      assert byte_size(embedded) > byte_size(pdf)

      # Result must still open in lopdf
      assert {:ok, _doc} = Quire.Pdf.open(embedded)
    end

    test "accepts string-keyed op data", %{pdf: pdf, png: png} do
      op_data = %{"pdf_bytes" => pdf, "page_index" => 0, "rect" => [0, 0, 10, 10], "png" => png}
      assert {:ok, _embedded} = SignaturePlace.apply(op_data, %{})
    end

    test "rejects missing fields", %{pdf: pdf} do
      assert {:error, "pdf_bytes is required"} = SignaturePlace.apply(%{}, %{})

      assert {:error, "page_index is required"} =
               SignaturePlace.apply(%{pdf_bytes: pdf}, %{})

      assert {:error, "rect is required"} =
               SignaturePlace.apply(%{pdf_bytes: pdf, page_index: 0}, %{})

      assert {:error, "png is required"} =
               SignaturePlace.apply(%{pdf_bytes: pdf, page_index: 0, rect: [0, 0, 1, 1]}, %{})
    end

    test "rejects wrongly-typed fields", %{pdf: pdf, png: png} do
      assert {:error, "page_index must be an integer"} =
               SignaturePlace.apply(
                 %{pdf_bytes: pdf, page_index: "0", rect: [0, 0, 1, 1], png: png},
                 %{}
               )

      assert {:error, "rect must be a list"} =
               SignaturePlace.apply(%{pdf_bytes: pdf, page_index: 0, rect: %{}, png: png}, %{})
    end

    test "propagates embedding errors", %{pdf: pdf} do
      op_data = %{pdf_bytes: pdf, page_index: 0, rect: [10, 10, 5, 5], png: "notpng"}
      assert {:error, :bad_rect} = SignaturePlace.apply(op_data, %{})
    end
  end

  describe "invert/2" do
    test "reverts to the pre-place revision" do
      assert {:ok, {:restore_revision, nil}} = SignaturePlace.invert(%{}, %{})
    end
  end
end
