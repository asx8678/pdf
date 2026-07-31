defmodule Quire.SplitTest do
  use ExUnit.Case, async: true

  alias Quire.Split

  @fixtures Path.expand("../fixtures/pdfs", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # blank doc with `count` pages
  defp blank_pdf(count) do
    {:ok, doc} = ExPdfium.new()

    doc =
      Enum.reduce(1..count, doc, fn _, acc ->
        {:ok, d} = ExPdfium.add_page(acc, {612.0, 792.0})
        d
      end)

    {:ok, bytes} = ExPdfium.save_to_bytes(doc)
    bytes
  end

  # blank doc with an outline at the given 0-based page indices
  defp outlined_pdf(count, bookmark_pages) do
    {:ok, q} = Quire.Pdf.open(blank_pdf(count))

    :ok =
      Quire.Pdf.set_outline(q, Enum.map(bookmark_pages, &%{title: "BM #{&1}", page: &1}))

    {:ok, bytes} = Quire.Pdf.save(q)
    bytes
  end

  defp output_pages(outputs) do
    Enum.map(outputs, fn %{bytes: bytes} ->
      {:ok, doc} = ExPdfium.open(bytes)
      {:ok, n} = ExPdfium.page_count(doc)
      n
    end)
  end

  # ── page_partitions/2: every N ─────────────────────────────────────────

  describe "every N pages" do
    test "splits into chunks of N" do
      assert {:ok, [[0, 1], [2, 3]]} = Split.page_partitions(blank_pdf(4), {:every_n, 2})
      assert {:ok, [[0, 1, 2], [3]]} = Split.page_partitions(blank_pdf(4), {:every_n, 3})
    end
  end

  # ── page_partitions/2: at bookmarks ────────────────────────────────────

  describe "at bookmarks" do
    test "splits at top-level bookmark destinations" do
      pdf = outlined_pdf(6, [1, 4])
      assert {:ok, [[0], [1, 2, 3], [4, 5]]} = Split.page_partitions(pdf, {:bookmarks, 1})
    end

    test "errors when the document has no bookmarks" do
      assert {:error, {:no_bookmarks, 1}} = Split.page_partitions(blank_pdf(4), {:bookmarks, 1})
    end
  end

  # ── page_partitions/2: by ranges ───────────────────────────────────────

  describe "by ranges" do
    test "one output per range group" do
      groups = [%{from: 1, to: 2}, [3]]
      assert {:ok, [[0, 1], [3]]} = Split.page_partitions(blank_pdf(4), {:ranges, groups})
    end

    test "rejects out-of-bounds groups" do
      assert {:error, {:page_out_of_bounds, [9], 4}} =
               Split.page_partitions(blank_pdf(4), {:ranges, [[9]]})
    end

    test "parse_range_groups expands specs" do
      assert {:ok, [%{from: 1, to: 3}, [4], %{from: 7, to: 9}]} =
               Split.parse_range_groups("1-3,5,7-9", 10)

      assert {:error, {"page 99 is out of range (document has 10 pages)", _}} =
               Split.parse_range_groups("1-99", 10)
    end
  end

  # ── page_partitions/2: by file size ────────────────────────────────────

  describe "by file size" do
    test "partitions so outputs stay under the target" do
      pdf = blank_pdf(10)
      {:ok, sizes} = Split.page_partitions(pdf, {:file_size, 600})

      {:ok, outputs} = Split.split(pdf, {:file_size, 600})
      assert length(outputs) > 1

      # every output stays under target (a single page may not exceed it)
      Enum.each(outputs, fn %{bytes: bytes} ->
        assert byte_size(bytes) <= 10_000
      end)

      # all pages accounted for
      assert Enum.sum(Enum.map(sizes, &length/1)) == 10
    end
  end

  # ── page_partitions/2: extract selected ────────────────────────────────

  describe "extract selected" do
    test "one single-page output per selected page" do
      assert {:ok, [[1], [3]]} = Split.page_partitions(blank_pdf(4), {:extract, [1, 3]})
    end
  end

  # ── split/3 end-to-end ─────────────────────────────────────────────────

  describe "split/3 output" do
    test "every N produces valid, individually openable PDFs" do
      # 4 pages
      pdf = fixture("mixed_page_sizes.pdf")
      assert {:ok, outputs} = Split.split(pdf, {:every_n, 2})
      assert Enum.map(outputs, & &1.name) == ["part-001.pdf", "part-002.pdf"]
      assert output_pages(outputs) == [2, 2]

      Enum.each(outputs, fn %{bytes: bytes} ->
        assert binary_part(bytes, 0, 5) == "%PDF-"
        assert {:ok, doc} = ExPdfium.open(bytes)
        assert {:ok, _} = ExPdfium.page_count(doc)
      end)
    end

    test "extract produces single-page outputs for the selection" do
      pdf = fixture("mixed_page_sizes.pdf")
      assert {:ok, outputs} = Split.split(pdf, {:extract, [0, 3]})
      assert output_pages(outputs) == [1, 1]
    end

    test "splitting 500_pages.pdf completes within budget" do
      pdf = fixture("500_pages.pdf")
      {micros, {:ok, outputs}} = :timer.tc(fn -> Split.split(pdf, {:every_n, 10}) end)

      assert length(outputs) == 50
      assert Enum.all?(output_pages(outputs), &(&1 == 10))
      # 500-page split should complete in well under a minute
      assert micros < 60_000_000
    end
  end

  # ── ZIP packaging ──────────────────────────────────────────────────────

  describe "zip_outputs/2" do
    test "packages outputs into a valid in-memory ZIP" do
      pdf = fixture("mixed_page_sizes.pdf")
      {:ok, outputs} = Split.split(pdf, {:every_n, 2})

      assert {:ok, zip_bytes} = Split.zip_outputs(outputs)
      assert binary_part(zip_bytes, 0, 2) == <<0x50, 0x4B>>

      # extract back and verify names + contents
      {:ok, entries} = :zip.extract(zip_bytes, [:memory])
      names = Enum.map(entries, fn {name, _} -> to_string(name) end)
      assert names == ["part-001.pdf", "part-002.pdf"]
    end
  end
end
