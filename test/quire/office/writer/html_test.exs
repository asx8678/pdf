defmodule Quire.Office.Writer.HtmlTest do
  use ExUnit.Case, async: true

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section
  alias Quire.Office.Writer.Html

  # ── Helper ─────────────────────────────────────────────────────────────────

  defp zip_files(files) do
    entries =
      Enum.map(files, fn {name, content} ->
        {String.to_charlist(name), content}
      end)

    {:ok, {_name, bytes}} = :zip.create(~c"archive", entries, [:memory])
    bytes
  end

  defp assert_html_has_tag(html, tag_regex) do
    assert html =~ tag_regex,
           "expected HTML to match:\n  #{inspect(tag_regex)}\ngot:\n  #{inspect(html)}"
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # Block type rendering
  # ═════════════════════════════════════════════════════════════════════════════

  describe "paragraph blocks" do
    test "renders a paragraph" do
      section = Section.new(:page) |> Section.add_block({:paragraph, "Hello World"})
      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|<p>Hello World</p>|)
    end

    test "escapes HTML special characters in paragraph text" do
      section = Section.new(:page) |> Section.add_block({:paragraph, "<b>bold</b> & \"quotes\""})
      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      refute html =~ "<b>bold</b>"
      assert_html_has_tag(html, ~r|&lt;b&gt;bold&lt;/b&gt;|)
      assert html =~ "&amp;"
      assert html =~ "&quot;"
    end
  end

  describe "heading blocks" do
    test "renders h1 through h6" do
      for level <- 1..6 do
        section = Section.new(:page) |> Section.add_block({:heading, "Level #{level}", level})
        layout = %Layout{sections: [section]}

        assert {:ok, html} = Html.write(layout, :html)
        assert_html_has_tag(html, ~r|<h#{level}>Level #{level}</h#{level}>|)
      end
    end

    test "clamps out-of-range heading levels" do
      section = Section.new(:page) |> Section.add_block({:heading, "Too high", 9})
      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|<h6>Too high</h6>|)
    end
  end

  describe "list blocks" do
    test "renders unordered list" do
      section = Section.new(:page) |> Section.add_block({:list, ["A", "B", "C"], false})
      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|<ul>|)
      assert_html_has_tag(html, ~r|<li>A</li>|)
      assert_html_has_tag(html, ~r|<li>B</li>|)
      assert_html_has_tag(html, ~r|<li>C</li>|)
    end

    test "renders ordered list" do
      section = Section.new(:page) |> Section.add_block({:list, ["First", "Second"], true})
      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|<ol>|)
      assert_html_has_tag(html, ~r|<li>First</li>|)
    end

    test "renders empty list" do
      section = Section.new(:page) |> Section.add_block({:list, [], false})
      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|<ul>\s*</ul>|s)
    end
  end

  describe "table blocks" do
    test "renders a table with headers and rows" do
      section =
        Section.new(:page)
        |> Section.add_block({:table, ["Name", "Age"], [["Alice", "30"], ["Bob", "25"]]})

      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|<thead>|)
      assert_html_has_tag(html, ~r|<th>Name</th>|)
      assert_html_has_tag(html, ~r|<th>Age</th>|)
      assert_html_has_tag(html, ~r|<tbody>|)
      assert_html_has_tag(html, ~r|<td>Alice</td>|)
      assert_html_has_tag(html, ~r|<td>30</td>|)
    end

    test "renders table with no headers" do
      section =
        Section.new(:page) |> Section.add_block({:table, [], [["just"], ["data"]]})

      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      refute html =~ "<thead>"
      assert_html_has_tag(html, ~r|<td>just</td>|)
    end

    test "renders empty table" do
      section = Section.new(:page) |> Section.add_block({:table, [], []})
      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|<table>|)
    end
  end

  describe "image blocks" do
    test "renders image as base64 data URI" do
      bytes = "fake-image-bytes"
      section = Section.new(:page) |> Section.add_block({:image, bytes, "Test image", "png"})
      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      b64 = Base.encode64(bytes)
      assert_html_has_tag(html, ~r|<img src="data:image/png;base64,#{Regex.escape(b64)}"|)
      assert html =~ ~s|alt="Test image"|
    end

    test "uses correct mime type based on extension" do
      section = Section.new(:page) |> Section.add_block({:image, <<>>, "", "jpg"})
      layout = %Layout{sections: [section]}
      assert {:ok, html} = Html.write(layout, :html)
      assert html =~ "data:image/jpeg"
    end

    test "uses octet-stream for unknown extensions" do
      section = Section.new(:page) |> Section.add_block({:image, <<>>, "", "xyz"})
      layout = %Layout{sections: [section]}
      assert {:ok, html} = Html.write(layout, :html)
      assert html =~ "data:application/octet-stream"
    end
  end

  describe "unknown block types" do
    test "renders a placeholder for unknown blocks" do
      section = Section.new(:page) |> Section.add_block({:unknown_type, "data"})
      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|class="unknown-block"|)
      assert html =~ "Unsupported block"
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # Section rendering
  # ═════════════════════════════════════════════════════════════════════════════

  describe "sections" do
    test "wraps each section in a div with type class" do
      s1 = Section.new(:page, "Page 1") |> Section.add_block({:paragraph, "text"})
      s2 = Section.new(:sheet) |> Section.add_block({:paragraph, "data"})
      layout = %Layout{sections: [s1, s2]}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|<div class="section-page">|)
      assert_html_has_tag(html, ~r|<div class="section-sheet">|)
    end

    test "renders section title as h1" do
      section = Section.new(:page, "My Title") |> Section.add_block({:paragraph, "content"})
      layout = %Layout{sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|<h1 class="section-title">My Title</h1>|)
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # Layout-level rendering
  # ═════════════════════════════════════════════════════════════════════════════

  describe "layout-level" do
    test "renders title in <title> tag" do
      section = Section.new(:page) |> Section.add_block({:paragraph, "content"})
      layout = %Layout{title: "My Document", sections: [section]}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|<title>My Document</title>|)
    end

    test "omits <title> when title is nil" do
      layout = %Layout{sections: [Section.new(:page)]}
      assert {:ok, html} = Html.write(layout, :html)
      refute html =~ "<title>"
    end

    test "produces valid HTML5 document structure" do
      layout = %Layout{
        title: "Test",
        sections: [Section.new(:page) |> Section.add_block({:paragraph, "Hello"})]
      }

      assert {:ok, html} = Html.write(layout, :html)
      assert html =~ "<!DOCTYPE html>"
      assert html =~ "<html"
      assert html =~ "<head>"
      assert html =~ "<meta charset=\"utf-8\""
      assert html =~ "<style>"
      assert html =~ "</head>"
      assert html =~ "<body>"
      assert html =~ "</body>"
      assert html =~ "</html>"
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # Conversion report notes
  # ═════════════════════════════════════════════════════════════════════════════

  describe "conversion report" do
    test "renders report notes in conversion-report div" do
      notes = [
        %{level: :info, message: "Parsed successfully", source: "docx"},
        %{level: :unsupported, message: "Skipped header content", source: "docx"}
      ]

      layout = %Layout{sections: [Section.new(:page)], report: notes}

      assert {:ok, html} = Html.write(layout, :html)
      assert_html_has_tag(html, ~r|class="conversion-report"|)
      assert html =~ "Conversion Report"
      assert html =~ "Parsed successfully"
      assert html =~ "Skipped header content"
    end

    test "omits report HTML when there are no notes" do
      layout = %Layout{sections: [Section.new(:page)]}
      assert {:ok, html} = Html.write(layout, :html)

      refute html =~ "Conversion Report",
             "expected no Conversion Report heading when report is empty"

      assert html =~ "<!DOCTYPE html>", "but HTML structure should still be present"
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # Full pipeline — read docx → write HTML
  # ═════════════════════════════════════════════════════════════════════════════

  describe "full pipeline (read docx → write HTML)" do
    test "round-trips a minimal docx" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
             <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
           </Types>
           """},
          {"_rels/.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
           </Relationships>
           """},
          {"word/document.xml",
           ~S"""
           <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
             <w:body>
               <w:p>
                 <w:r><w:t>Hello World</w:t></w:r>
               </w:p>
               <w:p>
                 <w:r><w:t>Second paragraph</w:t></w:r>
               </w:p>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, layout} = Quire.Office.Reader.read(bytes, "test.docx")
      assert {:ok, html} = Html.write(layout, :html)
      assert html =~ "<p>Hello World</p>"
      assert html =~ "<p>Second paragraph</p>"
    end

    test "produces no unsupported notes for a docx without headers/footers" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
             <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
           </Types>
           """},
          {"_rels/.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
           </Relationships>
           """},
          {"word/document.xml",
           ~S"""
           <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                       xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
             <w:body>
               <w:p>
                 <w:r><w:t>Body text</w:t></w:r>
               </w:p>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, layout} = Quire.Office.Reader.read(bytes, "test.docx")
      unsupported = Enum.filter(layout.report, &(&1.level == :unsupported))
      assert unsupported == []
    end

    test "notes unsupported header construct when document has headerReference" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
             <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
             <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
           </Types>
           """},
          {"_rels/.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
           </Relationships>
           """},
          {"word/_rels/document.xml.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rIdH" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
           </Relationships>
           """},
          {"word/header1.xml",
           ~S"""
           <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
             <w:p>
               <w:r><w:t>Document Header</w:t></w:r>
             </w:p>
           </w:hdr>
           """},
          {"word/document.xml",
           ~S"""
           <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                       xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
             <w:body>
               <w:p>
                 <w:r><w:t>Body text</w:t></w:r>
               </w:p>
               <w:sectPr>
                 <w:headerReference r:id="rIdH" w:type="default"/>
               </w:sectPr>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, layout} = Quire.Office.Reader.read(bytes, "test.docx")
      unsupported = Enum.filter(layout.report, &(&1.level == :unsupported))
      assert length(unsupported) == 1
      note = hd(unsupported)
      assert note.message =~ "Header"
      assert note.source == "docx"
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # report.docx fixture parsing
  # ═════════════════════════════════════════════════════════════════════════════

  describe "report.docx fixture" do
    test "parses report.docx and renders HTML" do
      {:ok, bytes} = File.read("test/fixtures/office/report.docx")
      assert {:ok, layout} = Quire.Office.Reader.read(bytes, "report.docx")
      assert {:ok, html} = Html.write(layout, :html)

      # The fixture just contains "Hello World - Report"
      assert html =~ "Hello World - Report"
      assert html =~ "<!DOCTYPE html>"
    end
  end
end
