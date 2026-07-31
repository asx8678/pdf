defmodule Quire.Gate4OfficeLayoutTest do
  # Gate 4 Item 3 — Office fixtures layout.
  #
  # Every fixture is pushed through the app's real conversion pipeline:
  #
  #   Office.Reader.read(bytes, filename)
  #     → Quire.Office.Writer.Html.write(layout, :html)
  #     → ChromicPDF.print_to_pdf({:html, html}, ...)
  #     → PDF bytes
  #     → ExPdfium text / image-object extraction
  #
  # and the extracted PDF content is asserted for structure — headings,
  # tables, lists and images in place. Pixel-perfection is explicitly NOT the
  # bar (plan3.md §13, R-03 line 2662).
  #
  # The five committed fixtures are intentionally minimal (T-016 corpus), so
  # alongside them the suite drives richer synthetic documents through the
  # identical pipeline to prove each construct (heading, table, list, image)
  # actually survives conversion into the PDF.
  #
  # Any test that drives Chromium must be serialised (§13 "async: true and
  # convert: 1 do not mix") — concurrent browser instances produce flaky
  # timeouts. This file is therefore async: false.
  use ExUnit.Case, async: false

  alias Quire.Office.Reader
  alias Quire.Office.Writer.Html

  @fixtures_dir Path.expand("../fixtures/office", __DIR__)

  # ── Pipeline helpers ──────────────────────────────────────────────────────

  defp fixture_bytes(name) do
    File.read!(Path.join(@fixtures_dir, name))
  end

  # The real pipeline: bytes → Layout → HTML → ChromicPDF → PDF bytes.
  defp convert_to_pdf(bytes, filename) do
    assert {:ok, layout} = Reader.read(bytes, filename)
    assert {:ok, html} = Html.write(layout, :html)

    opts = [discard_stderr: true, page_size: :A4, offline: true]

    case ChromicPDF.print_to_pdf({:html, html}, opts) do
      {:ok, base64} -> {:ok, layout, Base.decode64!(base64)}
      other -> other
    end
  end

  defp convert_fixture(name) do
    convert_to_pdf(fixture_bytes(name), name)
  end

  # Full-document text via ExPdfium (plain extract_text on each page).
  defp pdf_text(pdf_bytes) do
    {:ok, doc} = ExPdfium.open_blob(pdf_bytes)
    {:ok, count} = ExPdfium.page_count(doc)

    text =
      Enum.map_join(0..(count - 1), "\n", fn page ->
        case ExPdfium.extract_text(doc, page) do
          {:ok, t} -> t
          _ -> ""
        end
      end)

    :ok = ExPdfium.close(doc)
    text
  end

  # Number of raster image objects per page (used for image assertions).
  defp pdf_image_object_counts(pdf_bytes) do
    {:ok, doc} = ExPdfium.open_blob(pdf_bytes)
    {:ok, count} = ExPdfium.page_count(doc)

    counts =
      Enum.map(0..(count - 1), fn page ->
        case ExPdfium.images(doc, page) do
          {:ok, images} -> length(images)
          _ -> 0
        end
      end)

    :ok = ExPdfium.close(doc)
    counts
  end

  # ExPdfium may emit \r\n line endings; normalise before matching.
  defp norm(text), do: text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

  # ── The five committed fixtures (§13) through the real pipeline ───────────

  describe "committed fixtures convert through the real pipeline" do
    test "report.docx renders its paragraph text into the PDF" do
      {:ok, _layout, pdf} = convert_fixture("report.docx")
      assert pdf =~ "%PDF"
      assert norm(pdf_text(pdf)) =~ "Hello World - Report"
    end

    test "budget.xlsx renders its table with headers and cells into the PDF" do
      {:ok, _layout, pdf} = convert_fixture("budget.xlsx")

      text = norm(pdf_text(pdf))
      # Sheet title, table headers and both data cells survive extraction.
      assert text =~ "Sheet1"
      assert text =~ "Item"
      assert text =~ "Amount"
      assert text =~ "Revenue"
      assert text =~ "$1000"
    end

    test "deck.pptx renders its slide heading into the PDF" do
      {:ok, layout, pdf} = convert_fixture("deck.pptx")

      # The reader produces a heading block for the title shape.
      assert Enum.any?(layout.sections, fn s ->
               Enum.any?(s.blocks, &match?({:heading, _, 1}, &1))
             end)

      assert norm(pdf_text(pdf)) =~ "Slide 1"
    end

    test "notes.odt renders its paragraph text into the PDF" do
      {:ok, _layout, pdf} = convert_fixture("notes.odt")
      assert norm(pdf_text(pdf)) =~ "Notes"
    end

    test "letter.rtf renders all four paragraphs into the PDF" do
      {:ok, layout, pdf} = convert_fixture("letter.rtf")

      paragraph_count =
        layout.sections
        |> Enum.flat_map(& &1.blocks)
        |> Enum.count(&match?({:paragraph, _}, &1))

      assert paragraph_count == 4

      text = norm(pdf_text(pdf))
      assert text =~ "Dear Sir or Madam,"
      assert text =~ "This is a letter."
      assert text =~ "Sincerely,"
      assert text =~ "Author"
    end
  end

  # ── Construct fidelity: headings / tables / lists / images ────────────────
  #
  # The committed fixtures cover paragraph, table and heading but no lists and
  # no images. These synthetic documents exercise the remaining constructs
  # through the *identical* pipeline (Reader → Writer.Html → ChromicPDF →
  # ExPdfium) so the gate's "headings, tables, lists and images in place" is
  # verified end-to-end.

  describe "construct fidelity through the real pipeline" do
    test "docx with heading, list, table and image keeps everything in the PDF" do
      # 1x1 red PNG.
      png =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )

      bytes = build_docx(png)

      {:ok, layout, pdf} = convert_to_pdf(bytes, "rich.docx")

      # Reader level: every construct present in the layout model.
      blocks = Enum.flat_map(layout.sections, & &1.blocks)

      assert Enum.any?(blocks, &match?({:heading, _, 1}, &1)), "heading block"
      assert Enum.any?(blocks, &match?({:list, _, _}, &1)), "list block"
      assert Enum.any?(blocks, &match?({:table, _, _}, &1)), "table block"
      assert Enum.any?(blocks, &match?({:image, _, _, _}, &1)), "image block"

      # PDF level: text survives extraction.
      text = norm(pdf_text(pdf))
      assert text =~ "Annual Report", "heading text in PDF"
      assert text =~ "Key Findings", "list item text in PDF"
      assert text =~ "Department", "table header in PDF"
      assert text =~ "Engineering", "table cell in PDF"

      # PDF level: the image is a real raster object on the page.
      assert Enum.sum(pdf_image_object_counts(pdf)) >= 1, "image object in PDF"
    end

    test "pptx with a bulleted list renders list items into the PDF" do
      bytes = build_pptx_with_list()

      {:ok, layout, pdf} = convert_to_pdf(bytes, "rich.pptx")

      assert Enum.any?(
               Enum.flat_map(layout.sections, & &1.blocks),
               &match?({:list, _, false}, &1)
             )

      text = norm(pdf_text(pdf))
      assert text =~ "First point"
      assert text =~ "Second point"
      assert text =~ "Third point"
    end

    test "odt with heading and list renders both into the PDF" do
      bytes = build_odt()

      {:ok, layout, pdf} = convert_to_pdf(bytes, "rich.odt")

      blocks = Enum.flat_map(layout.sections, & &1.blocks)
      assert Enum.any?(blocks, &match?({:heading, _, 1}, &1))
      assert Enum.any?(blocks, &match?({:list, _, _}, &1))

      text = norm(pdf_text(pdf))
      assert text =~ "Meeting Notes"
      assert text =~ "Agenda item one"
      assert text =~ "Agenda item two"
    end
  end

  # ── Synthetic document builders ───────────────────────────────────────────

  defp zip_files(files) do
    entries =
      Enum.map(files, fn {name, content} ->
        {String.to_charlist(name), content}
      end)

    {:ok, {_name, bytes}} = :zip.create(~c"archive", entries, [:memory])
    bytes
  end

  defp build_docx(png) do
    zip_files([
      {"[Content_Types].xml",
       ~S"""
       <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
       <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
         <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
         <Default Extension="xml" ContentType="application/xml"/>
         <Default Extension="png" ContentType="image/png"/>
         <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
         <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
         <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
       </Types>
       """},
      {"_rels/.rels",
       ~S"""
       <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
       </Relationships>
       """},
      {"word/styles.xml",
       ~S"""
       <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
         <w:style w:type="paragraph" w:styleId="Heading1">
           <w:name w:val="heading 1"/>
         </w:style>
       </w:styles>
       """},
      {"word/numbering.xml",
       ~S"""
       <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
         <w:abstractNum w:abstractNumId="0">
           <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
         </w:abstractNum>
         <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
       </w:numbering>
       """},
      {"word/_rels/document.xml.rels",
       ~S"""
       <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Id="rIdImg" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
       </Relationships>
       """},
      {"word/media/image1.png", png},
      {"word/document.xml",
       ~S"""
       <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
       <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                   xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                   xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                   xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
                   xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
         <w:body>
           <w:p>
             <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
             <w:r><w:t>Annual Report</w:t></w:r>
           </w:p>
           <w:p>
             <w:pPr><w:numPr><w:numId w:val="1"/></w:numPr></w:pPr>
             <w:r><w:t>Key Findings</w:t></w:r>
           </w:p>
           <w:p>
             <w:pPr><w:numPr><w:numId w:val="1"/></w:numPr></w:pPr>
             <w:r><w:t>Next Steps</w:t></w:r>
           </w:p>
           <w:tbl>
             <w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>
             <w:tr>
               <w:tc><w:p><w:r><w:t>Department</w:t></w:r></w:p></w:tc>
               <w:tc><w:p><w:r><w:t>Headcount</w:t></w:r></w:p></w:tc>
             </w:tr>
             <w:tr>
               <w:tc><w:p><w:r><w:t>Engineering</w:t></w:r></w:p></w:tc>
               <w:tc><w:p><w:r><w:t>42</w:t></w:r></w:p></w:tc>
             </w:tr>
           </w:tbl>
           <w:p>
             <w:r>
               <w:drawing>
                 <wp:inline distT="0" distB="0" distL="0" distR="0">
                   <wp:extent cx="100000" cy="100000"/>
                   <wp:docPr id="1" name="Picture 1" descr="chart"/>
                   <a:graphic>
                     <a:graphicData>
                       <pic:pic>
                         <pic:blipFill><a:blip r:embed="rIdImg"/></pic:blipFill>
                         <pic:spPr/>
                       </pic:pic>
                     </a:graphicData>
                   </a:graphic>
                 </wp:inline>
               </w:drawing>
             </w:r>
           </w:p>
         </w:body>
       </w:document>
       """}
    ])
  end

  defp build_pptx_with_list do
    zip_files([
      {"[Content_Types].xml",
       ~S"""
       <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
         <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
         <Default Extension="xml" ContentType="application/xml"/>
         <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
         <Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
       </Types>
       """},
      {"_rels/.rels",
       ~S"""
       <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
       </Relationships>
       """},
      {"ppt/presentation.xml",
       ~S"""
       <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                       xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                       xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
         <p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst>
         <p:sldSz cx="9144000" cy="6858000"/>
       </p:presentation>
       """},
      {"ppt/_rels/presentation.xml.rels",
       ~S"""
       <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
       </Relationships>
       """},
      {"ppt/slides/slide1.xml",
       ~S"""
       <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
              xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
              xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
         <p:cSld><p:spTree>
           <p:nvGrpSpPr><p:cNvPr id="1" name=""/></p:nvGrpSpPr>
           <p:grpSpPr/>
           <p:sp>
             <p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
             <p:spPr/>
             <p:txBody><a:bodyPr/><a:lstStyle/>
               <a:p><a:r><a:t>Roadmap</a:t></a:r></a:p>
             </p:txBody>
           </p:sp>
           <p:sp>
             <p:nvSpPr><p:cNvPr id="3" name="Text Placeholder 2"/><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr>
             <p:spPr/>
             <p:txBody><a:bodyPr/><a:lstStyle/>
               <a:p lvl="1"><a:r><a:t>First point</a:t></a:r></a:p>
               <a:p lvl="1"><a:r><a:t>Second point</a:t></a:r></a:p>
               <a:p lvl="1"><a:r><a:t>Third point</a:t></a:r></a:p>
             </p:txBody>
           </p:sp>
         </p:spTree></p:cSld>
       </p:sld>
       """}
    ])
  end

  defp build_odt do
    content_xml = ~s|<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
  <office:body>
    <office:text>
      <text:h text:outline-level="1">Meeting Notes</text:h>
      <text:list>
        <text:list-item><text:p>Agenda item one</text:p></text:list-item>
        <text:list-item><text:p>Agenda item two</text:p></text:list-item>
      </text:list>
    </office:text>
  </office:body>
</office:document-content>|

    zip_files([
      {"mimetype", "application/vnd.oasis.opendocument.text"},
      {"META-INF/manifest.xml",
       ~s|<?xml version="1.0" encoding="UTF-8"?>\n<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>|},
      {"content.xml", content_xml}
    ])
  end
end
