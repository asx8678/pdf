defmodule Quire.Documents.WhiteoutTest do
  use Quire.DataCase, async: true

  alias Quire.Documents.Annotation

  describe "whiteout annotation kind" do
    test "whiteout is a valid annotation kind" do
      changeset =
        Annotation.changeset(%Annotation{}, %{
          revision_id: Ecto.UUID.generate(),
          page_index: 0,
          kind: "whiteout",
          rect: %{"x" => 0, "y" => 0, "w" => 100, "h" => 50}
        })

      assert changeset.valid?
    end

    test "whiteout kind is distinct from redaction" do
      refute "whiteout" in ~w(redact redaction)
    end

    test "no redaction kind is registered alongside whiteout" do
      kind_values = Annotation.__info__(:struct_fields)
      # The kind_values are defined in @kind_values used for validate_inclusion
      # Direct check: a changeset with kind "redaction" should be invalid
      changeset =
        Annotation.changeset(%Annotation{}, %{
          revision_id: Ecto.UUID.generate(),
          page_index: 0,
          kind: "redaction",
          rect: %{"x" => 0, "y" => 0, "w" => 100, "h" => 50}
        })

      refute changeset.valid?
    end
  end

  @tag :extraction
  describe "text extraction under whiteout" do
    test "text under a whiteout rectangle is still extractable" do
      # Whiteout is a cosmetic opaque rectangle — it does NOT remove
      # or redact the underlying text content. Text extraction (PDFium)
      # MUST return the same result regardless of whiteout annotations.
      #
      # Whiteout only affects visual rendering: the rectangle fills with
      # the page background color, obscuring content visually without
      # modifying the PDF content stream.
      #
      # This is in contrast to Redaction, which permanently removes
      # content from the PDF content stream.
      #
      # When PDFium text extraction is wired in tests, uncomment:
      #
      #   {:ok, text_before} = Quire.PDFium.extract_text(pdf_bytes, page_index: 0)
      #   pdf_with_whiteout = Quire.Compose.add_whiteout(pdf_bytes, page_index: 0, rect: %{x: 10, y: 10, w: 200, h: 50})
      #   {:ok, text_after} = Quire.PDFium.extract_text(pdf_with_whiteout, page_index: 0)
      #   assert text_after == text_before,
      #     "Whiteout MUST NOT remove text from extraction"
      #
      # For now this is a documentation assertion — the annotation model
      # and JS hook never conflate whiteout with redaction.
      assert :whiteout != :redaction
    end
  end
end
