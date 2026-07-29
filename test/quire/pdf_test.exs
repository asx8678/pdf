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

      assert :ok = Quire.Pdf.set_outline(doc, [%{title: "Ueberschrift - 目次", page: 0}])
      {:ok, saved} = Quire.Pdf.save(doc)
      {:ok, reopened} = Quire.Pdf.open(saved)

      assert {:ok, [%{title: "Ueberschrift - 目次", page: 0, children: []}]} =
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

  describe "outline/1 with named destinations" do
    defp named_dest_pdf(pages) do
      {:ok, doc} = ExPdfium.new()

      doc =
        Enum.reduce(1..pages, doc, fn _, acc ->
          {:ok, next} = ExPdfium.add_page(acc, {595.0, 842.0})
          next
        end)

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, doc} = Quire.Pdf.open(bytes)

      doc
    end

    defp link_named_dest(doc, name, page_obj_id, dest_name) do
      :ok = Quire.Pdf.set_object(doc, 50, %{"/Names" => [dest_name, {:ref, 60, 0}]})
      :ok = Quire.Pdf.set_object(doc, 60, [{:ref, page_obj_id, 0}, {:name, "XYZ"}, 0, 0, nil])

      {:ok, cat} = Quire.Pdf.catalog(doc)
      :ok = Quire.Pdf.set_object(doc, 1, Map.put(cat, "/Dests", {:ref, 50, 0}))

      :ok =
        Quire.Pdf.set_object(
          doc,
          80,
          %{
            "/Type" => {:name, "Outlines"},
            "/First" => {:ref, 70, 0},
            "/Last" => {:ref, 70, 0},
            "/Count" => 1
          }
        )

      :ok =
        Quire.Pdf.set_object(doc, 70, %{
          "/Title" => name,
          "/Dest" => dest_name,
          "/Parent" => {:ref, 80, 0}
        })

      {:ok, cat2} = Quire.Pdf.catalog(doc)

      :ok =
        Quire.Pdf.set_object(
          doc,
          1,
          Map.merge(cat2, %{"/Outlines" => {:ref, 80, 0}, "/Dests" => {:ref, 50, 0}})
        )

      :ok
    end

    test "resolves a named destination from a string Dest key" do
      doc = named_dest_pdf(3)
      :ok = link_named_dest(doc, "Chap1", 5, "chap1")

      assert {:ok, [%{title: "Chap1", page: 1}]} = Quire.Pdf.outline(doc)
    end

    test "resolves a named destination from a Name Dest key" do
      doc = named_dest_pdf(3)

      :ok = Quire.Pdf.set_object(doc, 50, %{"/Names" => ["t2", {:ref, 60, 0}]})
      :ok = Quire.Pdf.set_object(doc, 60, [{:ref, 6, 0}, {:name, "XYZ"}, 0, 0, nil])
      {:ok, cat} = Quire.Pdf.catalog(doc)
      :ok = Quire.Pdf.set_object(doc, 1, Map.put(cat, "/Dests", {:ref, 50, 0}))

      :ok =
        Quire.Pdf.set_object(
          doc,
          80,
          %{
            "/Type" => {:name, "Outlines"},
            "/First" => {:ref, 71, 0},
            "/Last" => {:ref, 71, 0},
            "/Count" => 1
          }
        )

      :ok =
        Quire.Pdf.set_object(
          doc,
          71,
          %{"/Title" => "T2", "/Dest" => {:name, "t2"}, "/Parent" => {:ref, 80, 0}}
        )

      {:ok, cat2} = Quire.Pdf.catalog(doc)

      :ok =
        Quire.Pdf.set_object(
          doc,
          1,
          Map.merge(cat2, %{"/Outlines" => {:ref, 80, 0}, "/Dests" => {:ref, 50, 0}})
        )

      assert {:ok, [%{title: "T2", page: 2}]} = Quire.Pdf.outline(doc)
    end

    test "resolves a named destination through a GoTo action" do
      doc = named_dest_pdf(3)

      :ok = Quire.Pdf.set_object(doc, 50, %{"/Names" => ["gt", {:ref, 60, 0}]})
      :ok = Quire.Pdf.set_object(doc, 60, [{:ref, 4, 0}, {:name, "XYZ"}, 0, 0, nil])
      {:ok, cat} = Quire.Pdf.catalog(doc)
      :ok = Quire.Pdf.set_object(doc, 1, Map.put(cat, "/Dests", {:ref, 50, 0}))

      :ok =
        Quire.Pdf.set_object(
          doc,
          82,
          %{
            "/Title" => "GoTo",
            "/A" => %{"/S" => {:name, "GoTo"}, "/D" => "gt"},
            "/Parent" => {:ref, 83, 0}
          }
        )

      :ok =
        Quire.Pdf.set_object(
          doc,
          83,
          %{
            "/Type" => {:name, "Outlines"},
            "/First" => {:ref, 82, 0},
            "/Last" => {:ref, 82, 0},
            "/Count" => 1
          }
        )

      {:ok, cat2} = Quire.Pdf.catalog(doc)

      :ok =
        Quire.Pdf.set_object(
          doc,
          1,
          Map.merge(cat2, %{"/Outlines" => {:ref, 83, 0}, "/Dests" => {:ref, 50, 0}})
        )

      assert {:ok, [%{title: "GoTo", page: 0}]} = Quire.Pdf.outline(doc)
    end

    test "returns nil for a non-existent named destination" do
      doc = named_dest_pdf(3)

      :ok =
        Quire.Pdf.set_object(
          doc,
          80,
          %{
            "/Type" => {:name, "Outlines"},
            "/First" => {:ref, 72, 0},
            "/Last" => {:ref, 72, 0},
            "/Count" => 1
          }
        )

      :ok =
        Quire.Pdf.set_object(
          doc,
          72,
          %{
            "/Title" => "Missing",
            "/Dest" => "nonexistent",
            "/Parent" => {:ref, 80, 0}
          }
        )

      {:ok, catalog} = Quire.Pdf.catalog(doc)

      :ok =
        Quire.Pdf.set_object(
          doc,
          1,
          Map.merge(catalog, %{"/Outlines" => {:ref, 80, 0}})
        )

      assert {:ok, [%{title: "Missing", page: nil}]} = Quire.Pdf.outline(doc)
    end

    test "round-trips through save and reopen" do
      doc = named_dest_pdf(3)
      :ok = link_named_dest(doc, "RT", 6, "rt")

      {:ok, saved} = Quire.Pdf.save(doc)
      {:ok, reopened} = Quire.Pdf.open(saved)

      assert {:ok, [%{title: "RT", page: 2}]} = Quire.Pdf.outline(reopened)
    end

    test "still resolves a direct array Dest (regression)" do
      doc = named_dest_pdf(3)

      :ok =
        Quire.Pdf.set_object(
          doc,
          80,
          %{
            "/Type" => {:name, "Outlines"},
            "/First" => {:ref, 74, 0},
            "/Last" => {:ref, 74, 0},
            "/Count" => 1
          }
        )

      :ok =
        Quire.Pdf.set_object(
          doc,
          74,
          %{
            "/Title" => "Direct",
            "/Dest" => [{:ref, 4, 0}, {:name, "XYZ"}, 0, 0, nil],
            "/Parent" => {:ref, 80, 0}
          }
        )

      {:ok, catalog} = Quire.Pdf.catalog(doc)

      :ok =
        Quire.Pdf.set_object(
          doc,
          1,
          Map.merge(catalog, %{"/Outlines" => {:ref, 80, 0}})
        )

      assert {:ok, [%{title: "Direct", page: 0}]} = Quire.Pdf.outline(doc)
    end
  end

  describe "save_with/2" do
    test "object streams produce a binary no larger than a plain save" do
      source = blank_pdf(60)

      {:ok, plain_doc} = Quire.Pdf.open(source)
      {:ok, compressed_doc} = Quire.Pdf.open(source)

      {:ok, plain} = Quire.Pdf.save(plain_doc)

      {:ok, compressed} =
        Quire.Pdf.save_with(compressed_doc, use_object_streams: true, use_xref_streams: true)

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

  describe "catalog/1" do
    test "returns the document catalog" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      {:ok, catalog} = Quire.Pdf.catalog(doc)

      assert catalog["/Type"] == {:name, "Catalog"}
      assert match?({:ref, _, _}, catalog["/Pages"])
    end
  end

  describe "allocate_object_id/1" do
    test "returns sequential unique ids" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))

      {:ok, id1} = Quire.Pdf.allocate_object_id(doc)
      {:ok, id2} = Quire.Pdf.allocate_object_id(doc)

      assert is_integer(id1) and id1 > 0
      assert is_integer(id2) and id2 > 0
      assert id1 != id2
      assert id2 == id1 + 1
    end

    test "returns fresh ids that can store and retrieve objects" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))

      {:ok, obj_id} = Quire.Pdf.allocate_object_id(doc)
      assert :ok = Quire.Pdf.set_object(doc, {obj_id, 0}, "stored_value")
      assert {:ok, "stored_value"} = Quire.Pdf.get_object(doc, {obj_id, 0})
    end
  end

  describe "get_object/2 and set_object/3" do
    test "round-trips an integer" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, 10, 42)
      assert {:ok, 42} = Quire.Pdf.get_object(doc, 10)
    end

    test "round-trips a string" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, 10, "hello")
      assert {:ok, val} = Quire.Pdf.get_object(doc, 10)
      assert is_binary(val)
      assert val == "hello"
    end

    test "round-trips a boolean" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, 10, true)
      assert {:ok, true} = Quire.Pdf.get_object(doc, 10)
      assert :ok = Quire.Pdf.set_object(doc, 11, false)
      assert {:ok, false} = Quire.Pdf.get_object(doc, 11)
    end

    test "round-trips nil as PDF null" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, 10, nil)
      assert {:ok, nil} = Quire.Pdf.get_object(doc, 10)
    end

    test "round-trips a name" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, 10, {:name, "TestName"})
      assert {:ok, {:name, "TestName"}} = Quire.Pdf.get_object(doc, 10)
    end

    test "round-trips a reference without dereferencing" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, 10, {:ref, 42, 3})
      assert {:ok, {:ref, 42, 3}} = Quire.Pdf.get_object(doc, 10)
    end

    test "round-trips a reference at maximum generation" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, 10, {:ref, 999, 65535})
      assert {:ok, {:ref, 999, 65535}} = Quire.Pdf.get_object(doc, 10)
    end

    test "round-trips a list" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, 10, [1, "two", {:name, "three"}])
      assert {:ok, [1, "two", {:name, "three"}]} = Quire.Pdf.get_object(doc, 10)
    end

    test "round-trips a dictionary" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      dict = %{"/Type" => {:name, "Test"}, "/Count" => 5}
      assert :ok = Quire.Pdf.set_object(doc, 10, dict)
      assert {:ok, ^dict} = Quire.Pdf.get_object(doc, 10)
    end

    test "round-trips a stream with binary data" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, 10, {:stream, %{}, "raw data"})
      assert {:ok, {:stream, _dict, data}} = Quire.Pdf.get_object(doc, 10)
      assert is_binary(data)
    end

    test "round-trips a complex nested structure" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))

      complex = %{
        "/Type" => {:name, "Nested"},
        "/Items" => [{:ref, 1, 0}, {:ref, 2, 5}],
        "/Dict" => %{"/Sub" => {:name, "inner"}, "/Flag" => true},
        "/Count" => 3
      }

      assert :ok = Quire.Pdf.set_object(doc, 50, complex)
      assert {:ok, ^complex} = Quire.Pdf.get_object(doc, 50)
    end

    test "accepts a bare integer id" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, 99, %{"/Val" => 1})
      assert {:ok, %{"/Val" => 1}} = Quire.Pdf.get_object(doc, 99)
    end

    test "accepts a tuple id" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, {88, 0}, %{"/Val" => 2})
      assert {:ok, %{"/Val" => 2}} = Quire.Pdf.get_object(doc, {88, 0})
    end

    test "returns {:error, :not_found} for a missing object" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert {:error, :not_found} = Quire.Pdf.get_object(doc, 999)
    end

    test "returns {:error, :bad_object} for an invalid object value" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert {:error, :bad_object} = Quire.Pdf.set_object(doc, 10, :not_a_pdf_value)
    end

    test "round-trips through save and reopen" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      complex = %{"/Items" => [{:ref, 1, 0}, {:ref, 2, 0}], "/Type" => {:name, "Dict"}}

      assert :ok = Quire.Pdf.set_object(doc, 50, complex)
      {:ok, saved} = Quire.Pdf.save(doc)

      {:ok, reopened} = Quire.Pdf.open(saved)
      assert {:ok, ^complex} = Quire.Pdf.get_object(reopened, 50)
    end

    test "stores objects independently across different ids" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      assert :ok = Quire.Pdf.set_object(doc, 1, "first")
      assert :ok = Quire.Pdf.set_object(doc, 2, "second")

      assert {:ok, "first"} = Quire.Pdf.get_object(doc, 1)
      assert {:ok, "second"} = Quire.Pdf.get_object(doc, 2)
    end
  end

  describe "large real round trips" do
    defp large_real_doc do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))

      # A value = 1.0e19 — Display serialises it as "10000000000000000000"
      # (no decimal point), which overflows i64 on re-read and drops the object.
      dict = %{
        "/Type" => {:name, "Page"},
        "/LargeReal" => 10_000_000_000_000_000_000.0
      }

      assert :ok = Quire.Pdf.set_object(doc, 50, dict)
      doc
    end

    test "save/1 preserves a large real" do
      doc = large_real_doc()
      {:ok, saved} = Quire.Pdf.save(doc)
      {:ok, reopened} = Quire.Pdf.open(saved)

      assert {:ok, %{"/LargeReal" => large}} = Quire.Pdf.get_object(reopened, 50)
      assert is_float(large), "large real came back as #{inspect(large)} (#{is_integer(large)})"
    end

    test "save_with/2 preserves a large real" do
      doc = large_real_doc()
      {:ok, saved} = Quire.Pdf.save_with(doc, use_object_streams: false, use_xref_streams: false)
      {:ok, reopened} = Quire.Pdf.open(saved)

      assert {:ok, %{"/LargeReal" => large}} = Quire.Pdf.get_object(reopened, 50)
      assert is_float(large), "large real came back as #{inspect(large)}"
    end

    test "incremental_save/1 preserves a large real" do
      doc = large_real_doc()
      {:ok, saved} = Quire.Pdf.incremental_save(doc)
      {:ok, reopened} = Quire.Pdf.open(saved)

      assert {:ok, %{"/LargeReal" => large}} = Quire.Pdf.get_object(reopened, 50)
      assert is_float(large), "large real came back as #{inspect(large)}"
    end

    test "integral real survives as float, not integer" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))

      dict = %{
        "/Type" => {:name, "Page"},
        "/Width" => 612.0,
        "/Height" => 792.0
      }

      assert :ok = Quire.Pdf.set_object(doc, 50, dict)
      {:ok, saved} = Quire.Pdf.save(doc)
      {:ok, reopened} = Quire.Pdf.open(saved)

      assert {:ok, %{"/Width" => w, "/Height" => h}} = Quire.Pdf.get_object(reopened, 50)
      assert is_float(w), "Width is #{inspect(w)} (integer)"
      assert is_float(h), "Height is #{inspect(h)} (integer)"
    end

    test "small integral real preserves type through incremental_save" do
      {:ok, doc} = Quire.Pdf.open(blank_pdf(1))
      dict = %{"/Val" => 42.0}
      assert :ok = Quire.Pdf.set_object(doc, 10, dict)

      {:ok, saved} = Quire.Pdf.incremental_save(doc)
      {:ok, reopened} = Quire.Pdf.open(saved)

      assert {:ok, %{"/Val" => val}} = Quire.Pdf.get_object(reopened, 10)
      assert is_float(val), "Value came back as #{inspect(val)}"
    end

    test "readers can parse a document with a large real" do
      doc = large_real_doc()
      {:ok, saved} = Quire.Pdf.save(doc)

      # An independent parser (ExPdfium) must be able to open the document.
      assert {:ok, _} = ExPdfium.open(saved)
    end
  end

  describe "Quire.Pdf.AcroForm" do
    defp form_pdf do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, {595.0, 842.0})
      {:ok, bytes} = ExPdfium.save_to_bytes(doc)

      {:ok, qdoc} = Quire.Pdf.open(bytes)

      widget = %{
        "/Type" => {:name, "Annot"},
        "/Subtype" => {:name, "Widget"},
        "/FT" => {:name, "Tx"},
        "/T" => "FullName",
        "/V" => "Ada Lovelace",
        "/DA" => "/Helv 12 Tf 0 g",
        "/Rect" => [50, 700, 400, 740],
        "/P" => {:ref, 4, 0},
        "/F" => 4
      }

      :ok = Quire.Pdf.set_object(qdoc, 10, widget)

      {:ok, page} = Quire.Pdf.get_object(qdoc, 4)
      :ok = Quire.Pdf.set_object(qdoc, 4, Map.put(page, "/Annots", [{:ref, 10, 0}]))

      :ok =
        Quire.Pdf.set_object(qdoc, 11, %{
          "/Fields" => [{:ref, 10, 0}],
          "/DR" => %{"/Font" => %{"/Helv" => {:ref, 20, 0}}}
        })

      {:ok, catalog} = Quire.Pdf.catalog(qdoc)
      :ok = Quire.Pdf.set_object(qdoc, 1, Map.put(catalog, "/AcroForm", {:ref, 11, 0}))

      qdoc
    end

    test "generate_appearances/1 writes /AP and content-stream with the value" do
      qdoc = form_pdf()

      assert :ok = Quire.Pdf.AcroForm.generate_appearances(qdoc)

      {:ok, widget} = Quire.Pdf.get_object(qdoc, 10)
      ap = Map.get(widget, "/AP", %{})
      assert %{"/N" => {:ref, stream_num, 0}} = ap

      {:ok, {:stream, _dict, data}} = Quire.Pdf.get_object(qdoc, {stream_num, 0})
      assert String.contains?(data, "Ada Lovelace")
      assert String.contains?(data, "BT")
      assert String.contains?(data, "Tf")
      assert String.contains?(data, "Tj")
    end

    test "generate_appearances/1 saves, flattens and renders the value" do
      qdoc = form_pdf()

      assert :ok = Quire.Pdf.AcroForm.generate_appearances(qdoc)

      {:ok, saved} = Quire.Pdf.save(qdoc)

      {:ok, pdfium_doc} = ExPdfium.open(saved)
      {:ok, flat_doc} = ExPdfium.flatten(pdfium_doc)

      {:ok, bitmap} =
        ExPdfium.render_page(flat_doc, 0,
          annotations: false,
          form_fields: false
        )

      raw = bitmap.data
      bpp = 4
      width = bitmap.width

      non_white =
        raw
        |> :binary.bin_to_list()
        |> Enum.chunk_every(bpp)
        |> Enum.with_index()
        |> Enum.any?(fn {pixels, idx} ->
          row = div(idx, width)
          col = rem(idx, width)

          col >= 55 and col <= 395 and row >= 105 and row <= 137 and
            (Enum.at(pixels, 0) < 200 or Enum.at(pixels, 1) < 200 or
               Enum.at(pixels, 2) < 200)
        end)

      assert non_white, "Expected text value to be visible after flatten"
    end

    test "fields without /V are skipped" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, {595.0, 842.0})
      {:ok, bytes} = ExPdfium.save_to_bytes(doc)

      {:ok, qdoc} = Quire.Pdf.open(bytes)

      widget = %{
        "/Type" => {:name, "Annot"},
        "/Subtype" => {:name, "Widget"},
        "/FT" => {:name, "Tx"},
        "/T" => "EmptyField",
        "/DA" => "/Helv 12 Tf 0 g",
        "/Rect" => [50, 700, 400, 740],
        "/P" => {:ref, 4, 0},
        "/F" => 4
      }

      :ok = Quire.Pdf.set_object(qdoc, 10, widget)
      {:ok, page} = Quire.Pdf.get_object(qdoc, 4)
      :ok = Quire.Pdf.set_object(qdoc, 4, Map.put(page, "/Annots", [{:ref, 10, 0}]))
      :ok = Quire.Pdf.set_object(qdoc, 11, %{"/Fields" => [{:ref, 10, 0}]})
      {:ok, catalog} = Quire.Pdf.catalog(qdoc)
      :ok = Quire.Pdf.set_object(qdoc, 1, Map.put(catalog, "/AcroForm", {:ref, 11, 0}))

      assert :ok = Quire.Pdf.AcroForm.generate_appearances(qdoc)

      {:ok, updated_widget} = Quire.Pdf.get_object(qdoc, 10)
      refute Map.has_key?(updated_widget, "/AP")
    end

    test "flatten WITHOUT generate_appearances produces no visible text" do
      qdoc = form_pdf()

      {:ok, saved} = Quire.Pdf.save(qdoc)
      {:ok, pdfium_doc} = ExPdfium.open(saved)
      {:ok, flat_doc} = ExPdfium.flatten(pdfium_doc)

      {:ok, bitmap} =
        ExPdfium.render_page(flat_doc, 0,
          annotations: false,
          form_fields: false
        )

      raw = bitmap.data
      bpp = 4
      width = bitmap.width

      non_white =
        raw
        |> :binary.bin_to_list()
        |> Enum.chunk_every(bpp)
        |> Enum.with_index()
        |> Enum.any?(fn {pixels, idx} ->
          row = div(idx, width)
          col = rem(idx, width)

          col >= 55 and col <= 395 and row >= 105 and row <= 137 and
            (Enum.at(pixels, 0) < 200 or Enum.at(pixels, 1) < 200 or
               Enum.at(pixels, 2) < 200)
        end)

      refute non_white,
             "Without generate_appearances, flatten bakes the old empty appearance"
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
