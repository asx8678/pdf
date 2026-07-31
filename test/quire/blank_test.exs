defmodule Quire.BlankTest do
  use ExUnit.Case, async: true

  alias Quire.Blank

  describe "create/2" do
    test "creates a valid single-page PDF with the requested size and orientation" do
      assert {:ok, pdf} = Blank.create(:a4, :portrait)
      assert binary_part(pdf, 0, 5) == "%PDF-"
      assert {:ok, doc} = ExPdfium.open(pdf)
      assert {:ok, 1} = ExPdfium.page_count(doc)

      assert Blank.page_size(:a4, :portrait) == {595.0, 842.0}
      assert Blank.page_size(:letter, :landscape) == {792.0, 612.0}
      assert Blank.page_size(:legal, :portrait) == {612.0, 1008.0}
    end
  end

  describe "render_template/3" do
    test "renders every template as a valid one-page PDF" do
      for template <- Blank.templates() do
        assert {:ok, pdf} = Blank.render_template(template.id, :a4, :portrait)
        assert {:ok, doc} = ExPdfium.open(pdf)
        assert {:ok, 1} = ExPdfium.page_count(doc)
      end
    end
  end
end
