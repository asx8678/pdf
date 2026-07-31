defmodule Quire.MergeTest do
  use ExUnit.Case, async: true

  alias Quire.Merge
  alias Vix.Vips.Image

  @fixtures Path.expand("../fixtures/pdfs", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # 3-page blank document with an outline (Alpha → p1, Beta → p3)
  defp outlined_pdf do
    {:ok, doc} = ExPdfium.new()

    doc =
      Enum.reduce(1..3, doc, fn _, acc ->
        {:ok, d} = ExPdfium.add_page(acc, {612.0, 792.0})
        d
      end)

    {:ok, blank} = ExPdfium.save_to_bytes(doc)
    {:ok, q} = Quire.Pdf.open(blank)
    :ok = Quire.Pdf.set_outline(q, [%{title: "Alpha", page: 0}, %{title: "Beta", page: 2}])
    {:ok, bytes} = Quire.Pdf.save(q)
    bytes
  end

  defp page_count(bytes) do
    {:ok, doc} = ExPdfium.open(bytes)
    {:ok, n} = ExPdfium.page_count(doc)
    n
  end

  defp outline(bytes) do
    {:ok, doc} = ExPdfium.open(bytes)
    ExPdfium.outline(doc)
  end

  # ── parse_ranges/2 ─────────────────────────────────────────────────────

  describe "parse_ranges/2" do
    test "expands numbers and hyphen ranges" do
      assert {:ok, [0, 1, 2, 4]} = Merge.parse_ranges("1-3,5", 10)
    end

    test "empty spec means all pages" do
      assert {:ok, [0, 1, 2]} = Merge.parse_ranges("", 3)
      assert {:ok, [0, 1, 2]} = Merge.parse_ranges("   ", 3)
    end

    test "dedupes and sorts" do
      assert {:ok, [0, 1, 3]} = Merge.parse_ranges("2,1,4-4,2", 10)
    end

    test "rejects out-of-bounds pages" do
      assert {:error, {msg, "1-99"}} = Merge.parse_ranges("1-99", 10)
      assert msg =~ "out of range"
    end

    test "rejects reversed and malformed ranges" do
      assert {:error, {msg, _}} = Merge.parse_ranges("5-2", 10)
      assert msg =~ "reversed"

      assert {:error, {msg2, _}} = Merge.parse_ranges("abc", 10)
      assert msg2 =~ "invalid page number"
    end
  end

  # ── merge/2: page assembly ─────────────────────────────────────────────

  describe "merge/2 page assembly" do
    test "merges whole documents in order" do
      simple = fixture("simple_text.pdf")
      acro = fixture("acroform.pdf")

      assert {:ok, merged} = Merge.merge([%{bytes: simple}, %{bytes: acro}])
      assert page_count(merged) == 2
      assert binary_part(merged, 0, 5) == "%PDF-"
    end

    test "per-file page ranges select a subset" do
      # mixed_page_sizes.pdf has 4 pages
      mixed = fixture("mixed_page_sizes.pdf")
      simple = fixture("simple_text.pdf")

      assert {:ok, merged} = Merge.merge([%{bytes: mixed, pages: [1, 3]}, %{bytes: simple}])
      assert page_count(merged) == 3
    end

    test "rejects page indices out of bounds" do
      simple = fixture("simple_text.pdf")
      assert {:error, {:page_out_of_bounds, [5], 1}} = Merge.merge([%{bytes: simple, pages: [5]}])
    end

    test "rejects empty source list" do
      assert {:error, :no_sources} = Merge.merge([])
    end
  end

  # ── merge/2: bookmarks ─────────────────────────────────────────────────

  describe "bookmarks" do
    test ":keep merges source outlines with page offsets" do
      outlined = outlined_pdf()
      simple = fixture("simple_text.pdf")

      assert {:ok, merged} = Merge.merge([%{bytes: outlined}, %{bytes: simple}], bookmarks: :keep)
      assert {:ok, entries} = outline(merged)
      assert Enum.any?(entries, &(&1.title == "Alpha" and &1.page == 0))
      assert Enum.any?(entries, &(&1.title == "Beta" and &1.page == 2))
    end

    test ":keep filters and remaps outline entries for ranged sources" do
      outlined = outlined_pdf()

      assert {:ok, merged} =
               Merge.merge([%{bytes: outlined, pages: [0, 2]}], bookmarks: :keep)

      assert {:ok, entries} = outline(merged)
      assert Enum.any?(entries, &(&1.title == "Alpha" and &1.page == 0))
      # Beta pointed at page 3 (index 2); with only pages 1 and 3 kept it maps to index 1
      assert Enum.any?(entries, &(&1.title == "Beta" and &1.page == 1))
    end

    test ":flatten removes the outline" do
      outlined = outlined_pdf()
      simple = fixture("simple_text.pdf")

      assert {:ok, merged} =
               Merge.merge([%{bytes: outlined}, %{bytes: simple}], bookmarks: :flatten)

      assert {:ok, []} = outline(merged)
    end
  end

  # ── merge/2: forms ─────────────────────────────────────────────────────

  describe "forms" do
    test ":keep preserves the AcroForm when the form doc is the base" do
      acro = fixture("acroform.pdf")
      simple = fixture("simple_text.pdf")

      assert {:ok, merged} = Merge.merge([%{bytes: acro}, %{bytes: simple}], forms: :keep)
      assert :binary.match(merged, "/AcroForm") != :nomatch
    end

    test ":discard strips the AcroForm from the merged output" do
      acro = fixture("acroform.pdf")
      simple = fixture("simple_text.pdf")

      assert {:ok, merged} = Merge.merge([%{bytes: acro}, %{bytes: simple}], forms: :discard)
      assert :binary.match(merged, "/AcroForm") == :nomatch
    end
  end

  # ── merge/2: page numbering ────────────────────────────────────────────

  describe "page numbering" do
    test "continue_numbering: true writes a single sequential label run" do
      outlined = outlined_pdf()
      simple = fixture("simple_text.pdf")

      assert {:ok, merged} =
               Merge.merge([%{bytes: outlined}, %{bytes: simple}], continue_numbering: true)

      assert :binary.match(merged, "/PageLabels") != :nomatch
      assert length(:binary.matches(merged, "/St 1")) == 1
    end

    test "continue_numbering: false restarts numbering per source" do
      outlined = outlined_pdf()
      simple = fixture("simple_text.pdf")

      assert {:ok, merged} =
               Merge.merge([%{bytes: outlined}, %{bytes: simple}], continue_numbering: false)

      assert length(:binary.matches(merged, "/St 1")) == 2
    end
  end

  # ── merge/2: Acrobat-compatibility smoke ───────────────────────────────

  describe "output validity" do
    test "merged output reopens in PDFium and round-trips through save" do
      simple = fixture("simple_text.pdf")
      acro = fixture("acroform.pdf")

      assert {:ok, merged} = Merge.merge([%{bytes: acro}, %{bytes: simple}])
      assert {:ok, doc} = ExPdfium.open(merged)
      assert {:ok, 2} = ExPdfium.page_count(doc)

      # Re-save through PDFium: the bytes stay a valid, re-openable PDF
      # (the Acrobat-compat smoke — the file opens in a strict reader).
      assert {:ok, resaved} = ExPdfium.save_to_bytes(doc)
      assert {:ok, doc2} = ExPdfium.open(resaved)
      assert {:ok, 2} = ExPdfium.page_count(doc2)
    end
  end
end
