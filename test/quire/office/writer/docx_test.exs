defmodule Quire.Office.Writer.DocxTest do
  use ExUnit.Case, async: true

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section
  alias Quire.Office.Writer.Docx

  describe "write/3" do
    test "returns {:ok, binary} for a valid docx" do
      layout = Layout.new()
      {:ok, docx} = Docx.write(layout, :docx)
      assert is_binary(docx)
      assert byte_size(docx) > 100
    end

    test "produces a valid ZIP archive" do
      layout = build_sample_layout()
      {:ok, docx} = Docx.write(layout, :docx)
      {:ok, entries} = :zip.list_dir(docx)

      entry_names =
        Enum.flat_map(entries, fn
          {:zip_comment, _} -> []
          {:zip_file, name, _, _, _, _} -> [List.to_string(name)]
        end)

      assert "[Content_Types].xml" in entry_names
      assert "_rels/.rels" in entry_names
      assert "word/document.xml" in entry_names
      assert "word/_rels/document.xml.rels" in entry_names
      assert "word/styles.xml" in entry_names
    end

    test "renders a paragraph" do
      layout =
        Layout.new()
        |> add_section(paragraph: "Hello World")

      doc_xml = extract_document_xml(layout)
      assert doc_xml =~ "Hello World"
      assert doc_xml =~ ~s[<w:p>]
    end

    test "renders headings" do
      layout =
        Layout.new()
        |> add_section(heading: {"Title", 1}, heading: {"Subtitle", 2}, heading: {"Section", 3})

      doc_xml = extract_document_xml(layout)
      assert doc_xml =~ "Title"
      assert doc_xml =~ "Subtitle"
      assert doc_xml =~ "Section"
      assert doc_xml =~ ~s[pStyle w:val="Heading1"]
      assert doc_xml =~ ~s[pStyle w:val="Heading2"]
      assert doc_xml =~ ~s[pStyle w:val="Heading3"]
    end

    test "renders ordered list" do
      layout =
        Layout.new()
        |> add_section(list: {["First", "Second", "Third"], true})

      doc_xml = extract_document_xml(layout)
      assert doc_xml =~ "First"
      assert doc_xml =~ "Second"
      assert doc_xml =~ "Third"
    end

    test "renders unordered list" do
      layout =
        Layout.new()
        |> add_section(list: {["Apples", "Oranges"], false})

      doc_xml = extract_document_xml(layout)
      assert doc_xml =~ "Apples"
      assert doc_xml =~ "Oranges"
    end

    test "renders table with headers and rows" do
      layout =
        Layout.new()
        |> add_section(
          table:
            {["Name", "Age"],
             [
               ["Alice", "30"],
               ["Bob", "25"]
             ]}
        )

      doc_xml = extract_document_xml(layout)
      assert doc_xml =~ "Name"
      assert doc_xml =~ "Age"
      assert doc_xml =~ "Alice"
      assert doc_xml =~ "Bob"
      assert doc_xml =~ ~s[tblHeader]
    end

    test "renders table without headers" do
      layout =
        Layout.new()
        |> add_section(table: {[], [["Cell A", "Cell B"]]})

      doc_xml = extract_document_xml(layout)
      assert doc_xml =~ "Cell A"
      assert doc_xml =~ "Cell B"
      refute doc_xml =~ "tblHeader"
    end

    test "renders multiple sections" do
      layout =
        Layout.new()
        |> add_section(paragraph: "Page 1")
        |> add_section(paragraph: "Page 2")

      doc_xml = extract_document_xml(layout)
      assert doc_xml =~ "Page 1"
      assert doc_xml =~ "Page 2"
    end

    test "renders conversion report when present" do
      layout =
        Layout.new()
        |> Layout.add_note(:unsupported, "Headers/footers not supported", "docx")
        |> Layout.add_note(:warn, "Font substitution applied", "docx")

      {:ok, docx} = Docx.write(layout, :docx)
      doc_xml = extract_document_xml(layout)
      assert doc_xml =~ "Conversion Report"
      assert doc_xml =~ "Headers/footers not supported"
      assert doc_xml =~ "Font substitution applied"
    end

    test "renders image with drawing XML" do
      section = Section.new(:page) |> Section.add_block({:image, <<0, 1, 2>>, "test", "png"})
      layout = %{Layout.new() | sections: [section]}
      doc_xml = extract_document_xml(layout)
      assert doc_xml =~ "<w:drawing>"
      assert doc_xml =~ "r:embed=\"rId3\""
    end

    test "returns error for unsupported format" do
      layout = Layout.new()
      assert {:error, _} = Docx.write(layout, :xlsx)
    end

    test "title adds a heading to document body" do
      layout = %{Layout.new() | title: "My Document"}
      {:ok, docx} = Docx.write(layout, :docx)
      doc_xml = extract_document_xml(layout)
      assert doc_xml =~ "My Document"
    end

    test "empty sections produce valid docx" do
      layout = Layout.new()
      {:ok, docx} = Docx.write(layout, :docx)
      assert is_binary(docx)
      assert byte_size(docx) > 100
    end

    test "realistic document" do
      section =
        Section.new(:page)
        |> Section.add_block({:heading, "Introduction", 1})
        |> Section.add_block({:paragraph, "This is a paragraph of text in the document."})
        |> Section.add_block({:heading, "Data", 2})
        |> Section.add_block({:table, ["Item", "Count"], [["Widgets", "42"], ["Gizmos", "17"]]})
        |> Section.add_block({:heading, "Notes", 3})
        |> Section.add_block({:list, ["First note", "Second note"], false})

      layout = %{Layout.new() | sections: [section]}
      doc_xml = extract_document_xml(layout)
      assert doc_xml =~ "Introduction"
      assert doc_xml =~ "This is a paragraph"
      assert doc_xml =~ "Widgets"
      assert doc_xml =~ "First note"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp add_section(layout, items) when is_list(items) do
    section =
      Enum.reduce(items, Section.new(:page), fn {type, content}, sec ->
        block =
          case {type, content} do
            {:paragraph, text} -> {:paragraph, text}
            {:heading, {text, level}} -> {:heading, text, level}
            {:list, {items, ordered}} -> {:list, items, ordered}
            {:table, {headers, rows}} -> {:table, headers, rows}
            {:image, {bytes, alt, ext}} -> {:image, bytes, alt, ext}
          end

        Section.add_block(sec, block)
      end)

    %{layout | sections: layout.sections ++ [section]}
  end

  defp add_section(layout, item = {_type, _content}) do
    add_section(layout, [item])
  end

  defp extract_document_xml(layout) do
    {:ok, docx} = Docx.write(layout, :docx)
    {:ok, entries} = :zip.extract(docx, [{:file_list, [~c"word/document.xml"]}, :memory])
    {~c"word/document.xml", doc_xml} = List.keyfind(entries, ~c"word/document.xml", 0)
    doc_xml
  end

  defp build_sample_layout do
    section =
      Section.new(:page)
      |> Section.add_block({:heading, "Sample Document", 1})
      |> Section.add_block({:paragraph, "Hello from Quire Office Writer!"})

    %{Layout.new() | sections: [section]}
  end
end
