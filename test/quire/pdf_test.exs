defmodule Quire.PdfTest do
  @moduledoc """
  Covers the properties `Quire.Pdf` exists for (ADR 0003 D1/D2/D3): outline
  write, object-stream compression, and an incremental update that leaves the
  original bytes alone.

  Fixtures are minted with `ExPdfium` rather than checked in, so the tests do
  not depend on the T-016 corpus and cannot drift from it.
  """

  use ExUnit.Case, async: true

  @outline [
    %{
      title: "Part One",
      page: 0,
      children: [
        %{title: "Chapter 1", page: 1},
        %{title: "Chapter 2", page: 2}
      ]
    },
    %{title: "Part Two", page: 3}
  ]

  describe "open/1" do
    test "parses a PDF and counts its pages" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(5))

      assert {:ok, 5} = Quire.Pdf.page_count(doc)
    end

    test "rejects something that is not a PDF" do
      assert {:error, :invalid_pdf} = Quire.Pdf.open("this is not a PDF")
    end
  end

  describe "open_file/1" do
    @tag :tmp_dir
    test "parses a PDF from disk", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "blank.pdf")
      File.write!(path, blank_pdf(2))

      {:ok, doc} = Quire.Pdf.open_file(path)

      assert {:ok, 2} = Quire.Pdf.page_count(doc)
    end

    @tag :tmp_dir
    test "reports a missing file", %{tmp_dir: tmp_dir} do
      assert {:error, :enoent} = Quire.Pdf.open_file(Path.join(tmp_dir, "absent.pdf"))
    end
  end

  describe "set_outline/2" do
    test "round-trips a nested outline through open -> set -> save -> reopen" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(5))
      assert {:ok, []} = Quire.Pdf.outline(doc)

      assert :ok = Quire.Pdf.set_outline(doc, @outline)
      assert {:ok, saved} = Quire.Pdf.save(doc)

      {:ok, reopened} = Quire.Pdf.open(saved)
      assert {:ok, read_back} = Quire.Pdf.outline(reopened)
      assert read_back == expected_nodes()
    end

    test "round-trips a title that is not ASCII" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))

      assert :ok = Quire.Pdf.set_outline(doc, [%{title: "Überschrift — 目次", page: 0}])
      {:ok, saved} = Quire.Pdf.save(doc)
      {:ok, reopened} = Quire.Pdf.open(saved)

      assert {:ok, [%{title: "Überschrift — 目次", page: 0, children: []}]} =
               Quire.Pdf.outline(reopened)
    end

    test "replaces rather than accumulates" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(5))

      assert :ok = Quire.Pdf.set_outline(doc, @outline)
      {:ok, once} = Quire.Pdf.save(doc)

      assert :ok = Quire.Pdf.set_outline(doc, @outline)
      {:ok, twice} = Quire.Pdf.save(doc)

      {:ok, reopened} = Quire.Pdf.open(twice)
      assert {:ok, read_back} = Quire.Pdf.outline(reopened)
      assert read_back == expected_nodes()

      # The old outline's objects are removed, so a second write must not make
      # the file meaningfully bigger. The slack covers lopdf renumbering the
      # cross-reference stream object on each save.
      assert byte_size(twice) - byte_size(once) < 64
    end

    test "clears the outline when given an empty list" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(5))
      assert :ok = Quire.Pdf.set_outline(doc, @outline)

      assert :ok = Quire.Pdf.set_outline(doc, [])
      {:ok, saved} = Quire.Pdf.save(doc)
      {:ok, reopened} = Quire.Pdf.open(saved)

      assert {:ok, []} = Quire.Pdf.outline(reopened)
    end

    test "fills in omitted :page and :children" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(3))

      # An entry with no page of its own inherits its first descendant's.
      assert :ok =
               Quire.Pdf.set_outline(doc, [
                 %{title: "Parent", children: [%{title: "Child", page: 2}]}
               ])

      {:ok, saved} = Quire.Pdf.save(doc)
      {:ok, reopened} = Quire.Pdf.open(saved)

      assert {:ok, [%{title: "Parent", page: 2, children: [%{title: "Child", page: 2}]}]} =
               Quire.Pdf.outline(reopened)
    end

    test "rejects a page index past the end without mutating the document" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(3))
      assert :ok = Quire.Pdf.set_outline(doc, [%{title: "Kept", page: 0}])

      assert {:error, :page_out_of_bounds} =
               Quire.Pdf.set_outline(doc, [%{title: "Too far", page: 3}])

      assert {:ok, [%{title: "Kept", page: 0}]} = Quire.Pdf.outline(doc)
    end

    test "returns an error rather than raising, for every shape of bad input" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))

      # set_outline/2's @spec promises :ok | {:error, atom()}. rustler's derived
      # decoder raises ErlangError on a shape it cannot decode, so every one of
      # these has to be caught in Elixir first. A negative :page in particular
      # is an ordinary 0-based/1-based caller slip, not an exceptional case.
      assert {:error, :page_out_of_bounds} = Quire.Pdf.set_outline(doc, [%{title: "a", page: -1}])

      assert {:error, :page_out_of_bounds} =
               Quire.Pdf.set_outline(doc, [%{title: "a", page: 99_999_999_999}])

      assert {:error, :bad_outline_title} = Quire.Pdf.set_outline(doc, [%{title: 42}])
      assert {:error, :bad_outline_title} = Quire.Pdf.set_outline(doc, [%{title: nil}])
      assert {:error, :bad_outline_title} = Quire.Pdf.set_outline(doc, [%{page: 0}])
      assert {:error, :bad_outline_entry} = Quire.Pdf.set_outline(doc, [:not_a_map])

      assert {:error, :bad_outline_entry} =
               Quire.Pdf.set_outline(doc, [%{title: "a", children: :not_a_list}])
    end

    test "rejects a tree deeper than the limit before entering the NIF" do
      deep = Enum.reduce(1..65, [], fn n, acc -> [%{title: "#{n}", page: 0, children: acc}] end)
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))

      assert {:error, :outline_too_deep} = Quire.Pdf.set_outline(doc, deep)
    end
  end

  describe "save_with/2" do
    test "object streams produce a binary no larger than a plain save" do
      source = blank_pdf(60)

      # Separate handles: lopdf's writer mutates the document it serialises
      # (see Quire.Pdf.save/1), so comparing two saves of one handle would be
      # comparing two different documents.
      {:ok, plain_doc} = Quire.Pdf.open(source)
      {:ok, compressed_doc} = Quire.Pdf.open(source)

      {:ok, plain} = Quire.Pdf.save(plain_doc)

      {:ok, compressed} =
        Quire.Pdf.save_with(compressed_doc, use_object_streams: true, use_xref_streams: true)

      # Strictly smaller, not merely "no larger" — object streams are the whole
      # reason save_with/2 exists (ADR 0003 D3, replacing dropped linearization),
      # so an equal-sized result means it silently did nothing.
      assert byte_size(compressed) < byte_size(plain)
      assert {:ok, 60} = Quire.Pdf.page_count(elem(Quire.Pdf.open(compressed), 1))
    end

    test "use_xref_streams alone is a no-op, as documented" do
      source = blank_pdf(10)
      {:ok, plain_doc} = Quire.Pdf.open(source)
      {:ok, xref_only_doc} = Quire.Pdf.open(source)

      {:ok, plain} = Quire.Pdf.save(plain_doc)

      {:ok, xref_only} =
        Quire.Pdf.save_with(xref_only_doc, use_object_streams: false, use_xref_streams: true)

      # lopdf's writer short-circuits to the plain writer when object streams
      # are off, ignoring use_xref_streams entirely. Pinned so that if lopdf
      # ever fixes it, this test tells us rather than the behaviour drifting.
      assert byte_size(xref_only) == byte_size(plain)
    end

    test "rejects a non-boolean option" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))

      assert {:error, :bad_option} = Quire.Pdf.save_with(doc, use_object_streams: :yes)
    end
  end

  describe "incremental_save/1" do
    test "reproduces the original bytes verbatim and appends the change" do
      source = blank_pdf(5)
      {:ok, doc} = Quire.Pdf.open(source)
      assert :ok = Quire.Pdf.set_outline(doc, @outline)

      assert {:ok, appended} = Quire.Pdf.incremental_save(doc)

      # The property the whole thing exists for: an existing /ByteRange over
      # the original revision still covers the same bytes.
      assert byte_size(appended) > byte_size(source)
      assert binary_part(appended, 0, byte_size(source)) == source

      {:ok, reopened} = Quire.Pdf.open(appended)
      assert {:ok, 5} = Quire.Pdf.page_count(reopened)
      assert {:ok, read_back} = Quire.Pdf.outline(reopened)
      assert read_back == expected_nodes()
    end

    test "appends a revision even when nothing changed" do
      source = blank_pdf(2)
      {:ok, doc} = Quire.Pdf.open(source)

      assert {:ok, appended} = Quire.Pdf.incremental_save(doc)
      assert binary_part(appended, 0, byte_size(source)) == source

      {:ok, reopened} = Quire.Pdf.open(appended)
      assert {:ok, 2} = Quire.Pdf.page_count(reopened)
    end
  end

  describe "output accepted by an independent parser" do
    # lopdf reading back what lopdf wrote proves only self-consistency. PDFium
    # is a separate implementation — and per ADR 0003 it is the one that cannot
    # *write* an outline, so its reader is exactly the check that matters.
    for {label, function, extra_args} <- [
          {"save/1", :save, []},
          {"save_with/2", :save_with, [[]]},
          {"incremental_save/1", :incremental_save, []}
        ] do
      test "PDFium reads the pages and outline written by #{label}" do
        {:ok, doc} = Quire.Pdf.open(blank_pdf(5))
        assert :ok = Quire.Pdf.set_outline(doc, @outline)

        assert {:ok, bytes} =
                 apply(Quire.Pdf, unquote(function), [doc | unquote(extra_args)])

        assert {:ok, pdfium_doc} = ExPdfium.open(bytes)

        assert {:ok, 5} = ExPdfium.page_count(pdfium_doc)
        assert {:ok, expected_nodes()} == ExPdfium.outline(pdfium_doc)
      end
    end
  end

  # `outline/1` always returns every key; the input form may omit some.
  defp expected_nodes do
    [
      %{
        title: "Part One",
        page: 0,
        children: [
          %{title: "Chapter 1", page: 1, children: []},
          %{title: "Chapter 2", page: 2, children: []}
        ]
      },
      %{title: "Part Two", page: 3, children: []}
    ]
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
