defmodule Quire.Office.ReaderTest do
  use ExUnit.Case, async: true

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section
  alias Quire.Office.Reader

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp zip_files(files) do
    entries =
      Enum.map(files, fn {name, content} ->
        {String.to_charlist(name), content}
      end)

    {:ok, {_name, bytes}} = :zip.create(~c"archive", entries, [:memory])
    bytes
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # .xlsx tests
  # ═════════════════════════════════════════════════════════════════════════════

  describe ".xlsx" do
    test "returns {:error, :invalid_xlsx} for empty input" do
      assert {:error, _} = Reader.read(<<>>, "test.xlsx")
    end

    test "returns {:ok, Layout} for a minimal xlsx" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
             <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
             <Default Extension="xml" ContentType="application/xml"/>
             <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
             <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
           </Types>
           """},
          {"_rels/.rels",
           ~S"""
           <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
           </Relationships>
           """},
          {"xl/workbook.xml",
           ~S"""
           <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
           <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                     xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
             <sheets>
               <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
             </sheets>
           </workbook>
           """},
          {"xl/_rels/workbook.xml.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
           </Relationships>
           """},
          {"xl/worksheets/sheet1.xml",
           ~S"""
           <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
           <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
             <sheetData>
               <row r="1">
                 <c r="A1" t="inlineStr"><is><t>Name</t></is></c>
                 <c r="B1" t="inlineStr"><is><t>Age</t></is></c>
               </row>
               <row r="2">
                 <c r="A2" t="inlineStr"><is><t>Alice</t></is></c>
                 <c r="B2"><v>30</v></c>
               </row>
               <row r="3">
                 <c r="A3" t="inlineStr"><is><t>Bob</t></is></c>
                 <c r="B3"><v>25</v></c>
               </row>
             </sheetData>
           </worksheet>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{type: :sheet, title: "Sheet1", blocks: blocks}]}} =
               Reader.read(bytes, "test.xlsx")

      assert blocks == [{:table, ["Name", "Age"], [["Alice", "30"], ["Bob", "25"]]}]
    end

    test "parses shared strings correctly" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
             <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
             <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
             <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
           </Types>
           """},
          {"_rels/.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
           </Relationships>
           """},
          {"xl/workbook.xml",
           ~S"""
           <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                     xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
             <sheets>
               <sheet name="Data" sheetId="1" r:id="rId1"/>
             </sheets>
           </workbook>
           """},
          {"xl/_rels/workbook.xml.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
           </Relationships>
           """},
          {"xl/sharedStrings.xml",
           ~S"""
           <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
             <si><t>Name</t></si>
             <si><t>Value</t></si>
             <si><t>A longer string</t></si>
           </sst>
           """},
          {"xl/worksheets/sheet1.xml",
           ~S"""
           <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
             <sheetData>
               <row r="1">
                 <c r="A1" t="s"><v>0</v></c>
                 <c r="B1" t="s"><v>1</v></c>
               </row>
               <row r="2">
                 <c r="A2" t="s"><v>2</v></c>
               </row>
             </sheetData>
           </worksheet>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{type: :sheet, title: "Data", blocks: blocks}]}} =
               Reader.read(bytes, "test.xlsx")

      assert blocks == [{:table, ["Name", "Value"], [["A longer string"]]}]
    end

    test "multiple sheets produce multiple sections" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
             <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
             <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
             <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
           </Types>
           """},
          {"_rels/.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
           </Relationships>
           """},
          {"xl/workbook.xml",
           ~S"""
           <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                     xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
             <sheets>
               <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
               <sheet name="Sheet2" sheetId="2" r:id="rId2"/>
             </sheets>
           </workbook>
           """},
          {"xl/_rels/workbook.xml.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
             <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
           </Relationships>
           """},
          {"xl/worksheets/sheet1.xml",
           ~S"""
           <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
             <sheetData>
               <row r="1"><c r="A1"><v>1</v></c></row>
             </sheetData>
           </worksheet>
           """},
          {"xl/worksheets/sheet2.xml",
           ~S"""
           <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
             <sheetData>
               <row r="1"><c r="A1"><v>2</v></c></row>
             </sheetData>
           </worksheet>
           """}
        ])

      assert {:ok, %Layout{sections: [s1, s2]}} = Reader.read(bytes, "test.xlsx")
      assert s1.title == "Sheet1"
      assert s2.title == "Sheet2"
    end

    test "empty sheets produce empty blocks" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
             <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
             <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
           </Types>
           """},
          {"_rels/.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
           </Relationships>
           """},
          {"xl/workbook.xml",
           ~S"""
           <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                     xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
             <sheets>
               <sheet name="Empty" sheetId="1" r:id="rId1"/>
             </sheets>
           </workbook>
           """},
          {"xl/_rels/workbook.xml.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
           </Relationships>
           """},
          {"xl/worksheets/sheet1.xml",
           ~S"""
           <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
             <sheetData>
             </sheetData>
           </worksheet>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{blocks: []}]}} = Reader.read(bytes, "test.xlsx")
    end

    test "returns error for unknown format" do
      assert {:error, :unknown_format} = Reader.read(<<>>, "test.unknown")
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # .pptx tests
  # ═════════════════════════════════════════════════════════════════════════════

  describe ".pptx" do
    test "returns {:error, _} for empty input" do
      assert {:error, _} = Reader.read(<<>>, "test.pptx")
    end

    test "parses a minimal pptx with one slide" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
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
           <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
           <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                           xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                           xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
             <p:sldIdLst>
               <p:sldId id="256" r:id="rId1"/>
             </p:sldIdLst>
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
           <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
           <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                  xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
             <p:spTree>
               <p:nvGrpSpPr>
                 <p:cNvPr id="1" name=""/>
               </p:nvGrpSpPr>
               <p:grpSpPr/>
               <p:sp>
                 <p:nvSpPr>
                   <p:cNvPr id="2" name="Title 1"/>
                   <p:nvPr>
                     <p:ph type="title"/>
                   </p:nvPr>
                 </p:nvSpPr>
                 <p:spPr/>
                 <p:txBody>
                   <a:bodyPr/>
                   <a:lstStyle/>
                   <a:p>
                     <a:r>
                       <a:t>Hello World</a:t>
                     </a:r>
                   </a:p>
                 </p:txBody>
               </p:sp>
               <p:sp>
                 <p:nvSpPr>
                   <p:cNvPr id="3" name="Text Placeholder 2"/>
                   <p:nvPr>
                     <p:ph type="body"/>
                   </p:nvPr>
                 </p:nvSpPr>
                 <p:spPr/>
                 <p:txBody>
                   <a:bodyPr/>
                   <a:lstStyle/>
                   <a:p>
                     <a:r>
                       <a:t>This is body text</a:t>
                     </a:r>
                   </a:p>
                   <a:p>
                     <a:r>
                       <a:t>Second paragraph</a:t>
                     </a:r>
                   </a:p>
                 </p:txBody>
               </p:sp>
             </p:spTree>
           </p:sld>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{type: :slide, title: "Slide 1", blocks: blocks}]}} =
               Reader.read(bytes, "test.pptx")

      assert blocks == [
               {:heading, "Hello World", 1},
               {:paragraph, "This is body text"},
               {:paragraph, "Second paragraph"}
             ]
    end

    test "parses a bullet list" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
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
             <p:sldIdLst>
               <p:sldId id="256" r:id="rId1"/>
             </p:sldIdLst>
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
             <p:spTree>
               <p:nvGrpSpPr><p:cNvPr id="1" name=""/></p:nvGrpSpPr>
               <p:grpSpPr/>
               <p:sp>
                 <p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
                 <p:spPr/>
                 <p:txBody>
                   <a:bodyPr/><a:lstStyle/>
                   <a:p>
                     <a:r><a:t>Top-level</a:t></a:r>
                   </a:p>
                 </p:txBody>
               </p:sp>
               <p:sp>
                 <p:nvSpPr><p:cNvPr id="3" name="Text Placeholder 2"/><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr>
                 <p:spPr/>
                 <p:txBody>
                   <a:bodyPr/><a:lstStyle/>
                   <a:p lvl="1">
                     <a:r><a:t>Item one</a:t></a:r>
                   </a:p>
                   <a:p lvl="1">
                     <a:r><a:t>Item two</a:t></a:r>
                   </a:p>
                   <a:p>
                     <a:r><a:t>Normal paragraph</a:t></a:r>
                   </a:p>
                 </p:txBody>
               </p:sp>
             </p:spTree>
           </p:sld>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.pptx")

      assert blocks == [
               {:heading, "Top-level", 1},
               {:list, ["Item one", "Item two"], false},
               {:paragraph, "Normal paragraph"}
             ]
    end

    test "multiple slides produce multiple sections" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
             <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
             <Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
             <Override PartName="/ppt/slides/slide2.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
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
             <p:sldIdLst>
               <p:sldId id="256" r:id="rId1"/>
               <p:sldId id="257" r:id="rId2"/>
             </p:sldIdLst>
           </p:presentation>
           """},
          {"ppt/_rels/presentation.xml.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
             <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
           </Relationships>
           """},
          {"ppt/slides/slide1.xml",
           ~S"""
           <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                  xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
             <p:spTree>
               <p:nvGrpSpPr><p:cNvPr id="1" name=""/></p:nvGrpSpPr><p:grpSpPr/>
               <p:sp>
                 <p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
                 <p:spPr/>
                 <p:txBody><a:bodyPr/><a:lstStyle/>
                   <a:p><a:r><a:t>Slide 1</a:t></a:r></a:p>
                 </p:txBody>
               </p:sp>
             </p:spTree>
           </p:sld>
           """},
          {"ppt/slides/slide2.xml",
           ~S"""
           <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                  xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
             <p:spTree>
               <p:nvGrpSpPr><p:cNvPr id="1" name=""/></p:nvGrpSpPr><p:grpSpPr/>
               <p:sp>
                 <p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
                 <p:spPr/>
                 <p:txBody><a:bodyPr/><a:lstStyle/>
                   <a:p><a:r><a:t>Slide 2</a:t></a:r></a:p>
                 </p:txBody>
               </p:sp>
             </p:spTree>
           </p:sld>
           """}
        ])

      assert {:ok, %Layout{sections: [s1, s2]}} = Reader.read(bytes, "test.pptx")
      assert s1.title == "Slide 1"
      assert s2.title == "Slide 2"
      assert hd(s1.blocks) == {:heading, "Slide 1", 1}
      assert hd(s2.blocks) == {:heading, "Slide 2", 1}
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # .odt tests
  # ═════════════════════════════════════════════════════════════════════════════

  describe ".odt" do
    test "returns {:error, _} for empty input" do
      assert {:error, _} = Reader.read(<<>>, "test.odt")
    end

    test "parses a minimal odt with a paragraph" do
      content_xml = ~s|<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
  <office:body>
    <office:text>
      <text:p>Hello ODT</text:p>
    </office:text>
  </office:body>
</office:document-content>|

      bytes = zip_files([{"content.xml", content_xml}])

      assert {:ok, %Layout{sections: [%Section{type: :page, blocks: blocks}]}} =
               Reader.read(bytes, "test.odt")

      assert blocks == [{:paragraph, "Hello ODT"}]
    end

    test "parses headings and lists" do
      content_xml = ~s|<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
  <office:body>
    <office:text>
      <text:h text:outline-level="1">Title</text:h>
      <text:p>A paragraph</text:p>
      <text:list>
        <text:list-item><text:p>Item A</text:p></text:list-item>
        <text:list-item><text:p>Item B</text:p></text:list-item>
      </text:list>
    </office:text>
  </office:body>
</office:document-content>|

      bytes = zip_files([{"content.xml", content_xml}])

      assert {:ok, %Layout{title: nil, sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.odt")

      assert blocks == [
               {:heading, "Title", 1},
               {:paragraph, "A paragraph"},
               {:list, ["Item A", "Item B"], false}
             ]
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # .ods tests
  # ═════════════════════════════════════════════════════════════════════════════

  describe ".ods" do
    test "returns {:error, _} for empty input" do
      assert {:error, _} = Reader.read(<<>>, "test.ods")
    end

    test "parses a minimal ods with a sheet" do
      content_xml = ~s|<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
  <office:body>
    <office:spreadsheet>
      <table:table table:name="Data">
        <table:table-row>
          <table:table-cell office:value-type="string"><text:p>Name</text:p></table:table-cell>
          <table:table-cell office:value-type="string"><text:p>Value</text:p></table:table-cell>
        </table:table-row>
        <table:table-row>
          <table:table-cell office:value-type="string"><text:p>Alpha</text:p></table:table-cell>
          <table:table-cell office:value-type="float" office:value="42"><text:p>42</text:p></table:table-cell>
        </table:table-row>
      </table:table>
    </office:spreadsheet>
  </office:body>
</office:document-content>|

      bytes = zip_files([{"content.xml", content_xml}])

      assert {:ok, %Layout{sections: [%Section{type: :sheet, title: "Data", blocks: blocks}]}} =
               Reader.read(bytes, "test.ods")

      assert blocks == [{:table, ["Name", "Value"], [["Alpha", "42"]]}]
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # .odp tests
  # ═════════════════════════════════════════════════════════════════════════════

  describe ".odp" do
    test "returns {:error, _} for empty input" do
      assert {:error, _} = Reader.read(<<>>, "test.odp")
    end

    test "parses a minimal odp with one slide" do
      content_xml = ~s|<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0">
  <office:body>
    <office:presentation>
      <draw:page draw:name="Slide 1">
        <draw:frame>
          <draw:text-box>
            <text:p>Slide content</text:p>
          </draw:text-box>
        </draw:frame>
      </draw:page>
    </office:presentation>
  </office:body>
</office:document-content>|

      bytes = zip_files([{"content.xml", content_xml}])

      assert {:ok, %Layout{sections: [%Section{type: :slide, title: "Slide 1", blocks: blocks}]}} =
               Reader.read(bytes, "test.odp")

      assert blocks == [{:heading, "Slide content", 1}]
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # .rtf tests
  # ═════════════════════════════════════════════════════════════════════════════

  describe ".rtf" do
    test "returns {:error, :invalid_rtf} for empty input" do
      assert {:error, :invalid_rtf} = Reader.read(<<>>, "test.rtf")
    end

    test "parses a simple rtf document" do
      rtf = "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Courier;}}\\pard Hello World\\par}"

      assert {:ok, %Layout{sections: [%Section{type: :page, blocks: blocks}]}} =
               Reader.read(rtf, "test.rtf")

      assert blocks == [{:paragraph, "Hello World"}]
    end

    test "parses multiple paragraphs" do
      rtf = "{\\rtf1\\ansi First para\\par Second para\\par}"

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(rtf, "test.rtf")

      assert blocks == [{:paragraph, "First para"}, {:paragraph, "Second para"}]
    end

    test "handles hex-escaped characters" do
      rtf = "{\\rtf1\\ansi R\\'e9sum\\'e9\\par}"

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(rtf, "test.rtf")

      assert blocks == [{:paragraph, "Résumé"}]
    end

    test "handles escaped braces and backslashes" do
      rtf = "{\\rtf1\\ansi Braces: \\{escaped\\} and \\\\backslash\\par}"

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(rtf, "test.rtf")

      assert blocks == [{:paragraph, "Braces: {escaped} and \\backslash"}]
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # .docx tests
  # ═════════════════════════════════════════════════════════════════════════════

  describe ".docx" do
    test "returns {:error, _} for empty input" do
      assert {:error, _} = Reader.read(<<>>, "test.docx")
    end

    test "parses a minimal docx with a paragraph" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
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
                 <w:r>
                   <w:t>Hello World</w:t>
                 </w:r>
               </w:p>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{type: :page, blocks: blocks}]}} =
               Reader.read(bytes, "test.docx")

      assert blocks == [{:paragraph, "Hello World"}]
    end

    test "parses multiple paragraphs" do
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
                 <w:r><w:t>First para</w:t></w:r>
               </w:p>
               <w:p>
                 <w:r><w:t>Second para</w:t></w:r>
               </w:p>
               <w:p>
                 <w:r><w:t>Third para</w:t></w:r>
               </w:p>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.docx")

      assert blocks == [
               {:paragraph, "First para"},
               {:paragraph, "Second para"},
               {:paragraph, "Third para"}
             ]
    end

    test "combines multiple runs within a paragraph" do
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
                 <w:r><w:t>Hello </w:t></w:r>
                 <w:r><w:t>World</w:t></w:r>
               </w:p>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.docx")

      assert blocks == [{:paragraph, "Hello World"}]
    end

    test "parses headings via style names" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
             <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
             <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
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
             <w:style w:type="paragraph" w:styleId="Heading2">
               <w:name w:val="heading 2"/>
             </w:style>
           </w:styles>
           """},
          {"word/document.xml",
           ~S"""
           <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
             <w:body>
               <w:p>
                 <w:pPr>
                   <w:pStyle w:val="Heading1"/>
                 </w:pPr>
                 <w:r><w:t>Title</w:t></w:r>
               </w:p>
               <w:p>
                 <w:pPr>
                   <w:pStyle w:val="Heading2"/>
                 </w:pPr>
                 <w:r><w:t>Subtitle</w:t></w:r>
               </w:p>
               <w:p>
                 <w:r><w:t>A paragraph</w:t></w:r>
               </w:p>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.docx")

      assert blocks == [
               {:heading, "Title", 1},
               {:heading, "Subtitle", 2},
               {:paragraph, "A paragraph"}
             ]
    end

    test "parses unordered lists" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
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
             <w:style w:type="paragraph" w:styleId="ListParagraph">
               <w:name w:val="List Paragraph"/>
             </w:style>
           </w:styles>
           """},
          {"word/numbering.xml",
           ~S"""
           <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
             <w:abstractNum w:abstractNumId="0">
               <w:lvl w:ilvl="0">
                 <w:numFmt w:val="bullet"/>
               </w:lvl>
             </w:abstractNum>
             <w:num w:numId="1">
               <w:abstractNumId w:val="0"/>
             </w:num>
           </w:numbering>
           """},
          {"word/document.xml",
           ~S"""
           <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
             <w:body>
               <w:p>
                 <w:pPr>
                   <w:numPr>
                     <w:numId w:val="1"/>
                   </w:numPr>
                 </w:pPr>
                 <w:r><w:t>Item A</w:t></w:r>
               </w:p>
               <w:p>
                 <w:pPr>
                   <w:numPr>
                     <w:numId w:val="1"/>
                   </w:numPr>
                 </w:pPr>
                 <w:r><w:t>Item B</w:t></w:r>
               </w:p>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.docx")

      assert blocks == [{:list, ["Item A", "Item B"], false}]
    end

    test "parses ordered lists" do
      bytes =
        zip_files([
          {"[Content_Types].xml",
           ~S"""
           <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
             <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
             <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
           </Types>
           """},
          {"_rels/.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
           </Relationships>
           """},
          {"word/numbering.xml",
           ~S"""
           <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
             <w:abstractNum w:abstractNumId="0">
               <w:lvl w:ilvl="0">
                 <w:numFmt w:val="decimal"/>
               </w:lvl>
             </w:abstractNum>
             <w:num w:numId="2">
               <w:abstractNumId w:val="0"/>
             </w:num>
           </w:numbering>
           """},
          {"word/document.xml",
           ~S"""
           <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
             <w:body>
               <w:p>
                 <w:pPr>
                   <w:numPr>
                     <w:numId w:val="2"/>
                   </w:numPr>
                 </w:pPr>
                 <w:r><w:t>First</w:t></w:r>
               </w:p>
               <w:p>
                 <w:pPr>
                   <w:numPr>
                     <w:numId w:val="2"/>
                   </w:numPr>
                 </w:pPr>
                 <w:r><w:t>Second</w:t></w:r>
               </w:p>
               <w:p>
                 <w:pPr>
                   <w:numPr>
                     <w:numId w:val="2"/>
                   </w:numPr>
                 </w:pPr>
                 <w:r><w:t>Third</w:t></w:r>
               </w:p>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.docx")

      assert blocks == [{:list, ["First", "Second", "Third"], true}]
    end

    test "parses a table" do
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
               <w:tbl>
                 <w:tblGrid>
                   <w:gridCol w:w="3000"/>
                   <w:gridCol w:w="3000"/>
                 </w:tblGrid>
                 <w:tr>
                   <w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc>
                   <w:tc><w:p><w:r><w:t>Age</w:t></w:r></w:p></w:tc>
                 </w:tr>
                 <w:tr>
                   <w:tc><w:p><w:r><w:t>Alice</w:t></w:r></w:p></w:tc>
                   <w:tc><w:p><w:r><w:t>30</w:t></w:r></w:p></w:tc>
                 </w:tr>
               </w:tbl>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.docx")

      assert blocks == [{:table, ["Name", "Age"], [["Alice", "30"]]}]
    end

    test "extracts title from docProps" do
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
          {"docProps/core.xml",
           ~S"""
           <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                              xmlns:dc="http://purl.org/dc/elements/1.1/">
             <dc:title>Report</dc:title>
           </cp:coreProperties>
           """},
          {"word/document.xml",
           ~S"""
           <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
             <w:body>
               <w:p><w:r><w:t>Content</w:t></w:r></w:p>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, %Layout{title: "Report", sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.docx")

      assert blocks == [{:paragraph, "Content"}]
    end

    test "handles text with hyperlinks" do
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
                 <w:r><w:t>Visit </w:t></w:r>
                 <w:hyperlink r:id="rId1">
                   <w:r><w:t>our site</w:t></w:r>
                 </w:hyperlink>
               </w:p>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.docx")

      assert blocks == [{:paragraph, "Visit our site"}]
    end

    test "extracts an image from media" do
      image_bytes = "fake-png-bytes"

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
          {"word/_rels/document.xml.rels",
           ~S"""
           <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
             <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
           </Relationships>
           """},
          {"word/media/image1.png", image_bytes},
          {"word/document.xml",
           ~S"""
           <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                       xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                       xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                       xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
                       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
             <w:body>
               <w:p>
                 <w:r>
                   <w:drawing>
                     <wp:inline>
                       <wp:docPr id="1" name="Picture 1" descr="A test image"/>
                       <a:graphic>
                         <a:graphicData>
                           <pic:pic>
                             <pic:blipFill>
                               <a:blip r:embed="rId2"/>
                             </pic:blipFill>
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

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.docx")

      assert blocks == [{:image, image_bytes, "A test image", "png"}]
    end

    test "empty paragraphs produce no blocks" do
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
               <w:p/>
               <w:p><w:r><w:t>Real text</w:t></w:r></w:p>
               <w:p/>
             </w:body>
           </w:document>
           """}
        ])

      assert {:ok, %Layout{sections: [%Section{blocks: blocks}]}} =
               Reader.read(bytes, "test.docx")

      assert blocks == [{:paragraph, "Real text"}]
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # dispatch tests
  # ═════════════════════════════════════════════════════════════════════════════

  describe "format dispatch" do
    test "unknown format returns {:error, :unknown_format}" do
      assert {:error, :unknown_format} = Reader.read(<<>>, "test.unknown")
    end
  end
end
