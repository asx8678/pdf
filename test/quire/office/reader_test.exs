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
           <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
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
end
