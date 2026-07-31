defmodule Quire.Pdf.OutlineTest do
  @moduledoc """
  Tests for `Quire.Pdf.Outline.transfer/3` and `filter_for_pages/2`.
  """

  use ExUnit.Case, async: true

  alias Quire.Pdf

  describe "transfer/3" do
    test "appends source outline entries with page offset" do
      dest = blank_pdf(3)
      {:ok, dest_doc} = Pdf.open(dest)

      source = blank_pdf(2)
      {:ok, source_doc} = Pdf.open(source)

      assert :ok = Pdf.set_outline(dest_doc, [%{title: "Dest Pg 0", page: 0}])

      assert :ok =
               Pdf.set_outline(source_doc, [
                 %{title: "Src Pg 0", page: 0},
                 %{title: "Src Pg 1", page: 1}
               ])

      assert :ok = Pdf.Outline.transfer(dest_doc, source_doc, 3)

      {:ok, entries} = Pdf.outline(dest_doc)
      assert length(entries) == 3

      # Original dest entry unchanged
      assert Enum.any?(entries, &(&1.title == "Dest Pg 0" and &1.page == 0))

      # Source entries shifted by 3
      assert Enum.any?(entries, &(&1.title == "Src Pg 0" and &1.page == 3))
      assert Enum.any?(entries, &(&1.title == "Src Pg 1" and &1.page == 4))
    end

    test "no-op when source has no outline" do
      dest = blank_pdf(3)
      {:ok, dest_doc} = Pdf.open(dest)

      source = blank_pdf(2)
      {:ok, source_doc} = Pdf.open(source)

      assert :ok = Pdf.set_outline(dest_doc, [%{title: "Dest Only", page: 0}])

      {:ok, []} = Pdf.outline(source_doc)

      assert :ok = Pdf.Outline.transfer(dest_doc, source_doc, 2)

      {:ok, entries} = Pdf.outline(dest_doc)
      assert length(entries) == 1
      assert entries == [%{title: "Dest Only", page: 0, children: []}]
    end

    test "works with nested outlines" do
      dest = blank_pdf(5)
      {:ok, dest_doc} = Pdf.open(dest)

      source = blank_pdf(3)
      {:ok, source_doc} = Pdf.open(source)

      dest_outline = [
        %{title: "Chapter 1", page: 0, children: [%{title: "Section 1.1", page: 1}]}
      ]

      assert :ok = Pdf.set_outline(dest_doc, dest_outline)

      source_outline = [%{title: "Appendix A", page: 0}]
      assert :ok = Pdf.set_outline(source_doc, source_outline)

      assert :ok = Pdf.Outline.transfer(dest_doc, source_doc, 5)

      {:ok, entries} = Pdf.outline(dest_doc)
      assert length(entries) == 2

      assert %{title: "Chapter 1", page: 0, children: [%{title: "Section 1.1", page: 1}]} =
               List.first(entries)

      assert %{title: "Appendix A", page: 5, children: []} = List.last(entries)
    end
  end

  describe "filter_for_pages/2" do
    test "keeps only entries for kept pages and remaps indices" do
      doc = blank_pdf(5)
      {:ok, qdoc} = Pdf.open(doc)

      assert :ok =
               Pdf.set_outline(qdoc, [
                 %{title: "Page 1", page: 0},
                 %{title: "Page 3", page: 2},
                 %{title: "Page 5", page: 4}
               ])

      assert :ok = Pdf.Outline.filter_for_pages(qdoc, [0, 2])

      {:ok, entries} = Pdf.outline(qdoc)
      assert length(entries) == 2

      assert Enum.any?(entries, &(&1.title == "Page 1" and &1.page == 0))
      assert Enum.any?(entries, &(&1.title == "Page 3" and &1.page == 1))
      refute Enum.any?(entries, &(&1.title == "Page 5"))
    end

    test "clears outline when no kept entries remain" do
      doc = blank_pdf(5)
      {:ok, qdoc} = Pdf.open(doc)

      assert :ok = Pdf.set_outline(qdoc, [%{title: "Only Page", page: 0}])

      assert :ok = Pdf.Outline.filter_for_pages(qdoc, [2])

      {:ok, entries} = Pdf.outline(qdoc)
      assert entries == []
    end

    test "keeps entries with page: nil if descendants survive" do
      doc = blank_pdf(3)
      {:ok, qdoc} = Pdf.open(doc)

      assert :ok =
               Pdf.set_outline(qdoc, [
                 %{title: "Parent", children: [%{title: "Child", page: 1}]}
               ])

      assert :ok = Pdf.Outline.filter_for_pages(qdoc, [1])

      {:ok, entries} = Pdf.outline(qdoc)
      assert length(entries) == 1

      assert %{title: "Parent", page: 0, children: [%{title: "Child", page: 0}]} =
               List.first(entries)
    end

    test "prunes entries with page: nil when no descendants survive" do
      doc = blank_pdf(3)
      {:ok, qdoc} = Pdf.open(doc)

      assert :ok =
               Pdf.set_outline(qdoc, [
                 %{title: "Parent", children: [%{title: "Child", page: 1}]}
               ])

      assert :ok = Pdf.Outline.filter_for_pages(qdoc, [0])

      {:ok, entries} = Pdf.outline(qdoc)
      assert entries == []
    end
  end

  defp blank_pdf(pages) when pages > 0 do
    {:ok, doc} = ExPdfium.new()

    doc =
      Enum.reduce(1..pages, doc, fn _, acc ->
        {:ok, next} = ExPdfium.add_page(acc, {595.0, 842.0})
        next
      end)

    {:ok, bytes} = ExPdfium.save_to_bytes(doc)
    bytes
  end
end
