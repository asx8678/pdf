#!/usr/bin/env elixir
# mix run scripts/generate_fixtures.exs
#
# Generates the PDF, Office, and image fixture corpus.
# Every fixture is built from scratch using raw PDF syntax or minimal ZIP XML.

defmodule GenerateFixtures do
  @pdf "test/fixtures/pdfs"
  @off "test/fixtures/office"
  @img "test/fixtures/images"

  def run do
    [@pdf, @off, @img] |> Enum.each(&File.mkdir_p!/1)
    pdfs(); office(); images()
    c = Enum.sum_by([@pdf, @off, @img], &(Path.wildcard(&1 <> "/*") |> length()))
    IO.puts("Generated #{c} fixtures")
  end

  # ── PDF helpers ─────────────────────────────────────────────────

  defp spdf(name, text, extra \\ [], catalog \\ "") do
    cs = "BT /F1 12 Tf 72 720 Td (#{esc(text)}) Tj ET\n"
    objs = [
      {1, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R #{catalog}>>\nendobj\n"},
      {2, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"},
      {3, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]\n   /Resources << /Font << /F1 4 0 R >> >>\n   /Contents 5 0 R >>\nendobj\n"},
      {4, "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"},
      {5, "5 0 obj\n<< /Length #{byte_size(cs)} >>\nstream\n#{cs}endstream\nendobj\n"}
    ] ++ extra |> Enum.sort()
    write(@pdf, name, assemble(objs))
  end

  defp assemble(objs) do
    hdr = "%PDF-1.7\n%\xFF\xFF\xFF\xFF\n"
    bdy = Enum.map_join(objs, fn {_, t} -> t end)
    {offs, _} = Enum.reduce(objs, {[], byte_size(hdr)}, fn {_, t}, {a, p} -> {[p | a], p + byte_size(t)} end)
    offs = Enum.reverse(offs)
    cnt = length(objs) + 1
    xl = Enum.map(offs, fn o -> "#{pad(o)} 00000 n\n" end) |> Enum.join()
    xr = byte_size(hdr <> bdy)
    hdr <> bdy <> "xref\n0 #{cnt}\n0000000000 65535 f \n#{xl}" <>
      "trailer\n<< /Size #{cnt} /Root 1 0 R >>\nstartxref\n#{xr}\n%%%%EOF\n"
  end

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 10, "0")
  defp esc(s), do: s |> String.replace("\\", "\\\\\\\\") |> String.replace("(", "\\(") |> String.replace(")", "\\)")
  defp write(dir, name, bytes), do: File.write!(Path.join(dir, name), bytes)

  defp multi_page(count) do
    cs = "BT /F1 12 Tf 72 720 Td (Page) Tj ET\n"
    cs_obj = {6, "6 0 obj\n<< /Length #{byte_size(cs)} >>\nstream\n#{cs}endstream\nendobj\n"}
    pages = Enum.map(0..(count-1), fn i -> n = 7 + i; {n, "#{n} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R >>\nendobj\n"} end)
    kids = Enum.map_join(pages, " ", fn {n, _} -> "#{n} 0 R" end)
    write(@pdf, "500_pages.pdf", assemble([
      {1, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"},
      {2, "2 0 obj\n<< /Type /Pages /Kids [#{kids}] /Count #{count} >>\nendobj\n"},
      {3, "3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"},
      cs_obj
    ] ++ pages))
  end

  defp big_image(count) do
    w = 1000; h = 200
    raw = :binary.copy(<<128>>, w * h)
    pages = Enum.map(0..(count-1), fn i ->
      in_ = 6 + i*3; cn_ = 7 + i*3; pn_ = 8 + i*3
      cs = "BT /F1 12 Tf 72 720 Td (I#{i}) Tj ET\n"
      img_src = IO.iodata_to_binary([
        "#{in_} 0 obj\n<< /Type /XObject /Subtype /Image /Width #{w} /Height #{h} /BitsPerComponent 8 /ColorSpace /DeviceGray /Length #{byte_size(raw)} >>\nstream\n",
        raw,
        "endstream\nendobj\n"
      ])
      [
        {in_, img_src},
        {cn_, "#{cn_} 0 obj\n<< /Length #{byte_size(cs)} >>\nstream\n#{cs}endstream\nendobj\n"},
        {pn_, "#{pn_} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Im0 #{in_} 0 R >> /Font << /F1 3 0 R >> >> /Contents #{cn_} 0 R >>\nendobj\n"}
      ]
    end) |> List.flatten()
    kids = Enum.map_join(0..(count-1), " ", fn i -> "#{8 + i*3} 0 R" end)
    write(@pdf, "50mb_images.pdf", assemble([
      {1, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"},
      {2, "2 0 obj\n<< /Type /Pages /Kids [#{kids}] /Count #{count} >>\nendobj\n"},
      {3, "3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"}
    ] ++ pages))
  end

  # ── Individual PDF fixtures ──────────────────────────────────────

  defp pdfs do
    spdf("simple_text.pdf", "Hello World")
    IO.puts("  simple_text.pdf")
    # Build manually so image /Resources lands on page, not catalog
    img_raw = :binary.copy(<<0>>, 600)
    scanned_ct = ""
    write(@pdf, "scanned_300dpi.pdf", assemble([
      {1, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"},
      {2, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"},
      {3, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]
   /Resources << /Font << /F1 4 0 R >> /XObject << /Im0 6 0 R >> >>
   /Contents 5 0 R >>\nendobj\n"},
      {4, "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"},
      {5, "5 0 obj\n<< /Length #{byte_size(scanned_ct)} >>\nstream\n#{scanned_ct}endstream\nendobj\n"},
      {6, IO.iodata_to_binary([
        "6 0 obj\n<< /Type /XObject /Subtype /Image /Width 300 /Height 2 /BitsPerComponent 8 /ColorSpace /DeviceGray /Length #{byte_size(img_raw)} >>\nstream\n",
        img_raw,
        "endstream\nendobj\n"
      ])}
    ]))
    IO.puts("  scanned_300dpi.pdf")
    spdf("cjk.pdf", "CJK placeholder"); IO.puts("  cjk.pdf")
    spdf("rtl_arabic.pdf", "RTL placeholder"); IO.puts("  rtl_arabic.pdf")

    # acroform.pdf
    spdf("acroform.pdf", "Form", [
      {6, "6 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Tx /T (text1) /Rect [72 700 200 720] /P 3 0 R >>\nendobj\n"}
    ], "/AcroForm << /Fields [6 0 R] /DR << /Font << /F1 4 0 R >> >> /NeedAppearances true >> ")
    |> then(fn _ -> IO.puts("  acroform.pdf") end)

    # xfa_form.pdf
    xfa = ~s|<?xml version="1.0"?><xdp:xdp xmlns:xdp="http://ns.adobe.com/xdp/"><form1><TextField1>Hello</TextField1></form1></xdp:xdp>|
    spdf("xfa_form.pdf", "XFA", [
      {6, "6 0 obj\n<</Type /EmbeddedFile /Length #{byte_size(xfa)}>> stream\n#{xfa}\nendstream\nendobj\n"}
    ], "/AcroForm << /XFA [6 0 R] /NeedAppearances true >> ")
    |> then(fn _ -> IO.puts("  xfa_form.pdf") end)

    # encrypted_user_pw.pdf, encrypted_owner_pw.pdf
    enc = "6 0 obj\n<< /Filter /Standard /V 2 /Length 128 /R 3 /O <00000000000000000000000000000000> /U <00000000000000000000000000000000> /P -4 >>\nendobj\n"
    spdf("encrypted_user_pw.pdf", "Encrypted", [{6, enc}], "/Encrypt 6 0 R "); IO.puts("  encrypted_user_pw.pdf")
    spdf("encrypted_owner_pw.pdf", "Encrypted", [{6, enc}], "/Encrypt 6 0 R "); IO.puts("  encrypted_owner_pw.pdf")

    # signed_pades.pdf
    spdf("signed_pades.pdf", "Signed", [
      {6, "6 0 obj\n<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /Contents <0000> /ByteRange [0 0 0 0] >>\nendobj\n"},
      {7, "7 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Sig /T (sig1) /Rect [72 700 200 720] /P 3 0 R /V 6 0 R >>\nendobj\n"}
    ], "/AcroForm << /Fields [7 0 R] >> "); IO.puts("  signed_pades.pdf")

    # tagged_accessible.pdf
    spdf("tagged_accessible.pdf", "Tagged", [
      {6, "6 0 obj\n<< /Type /StructTreeRoot /K 7 0 R /RoleMap << /Document /Document >> /ParentTree 9 0 R >>\nendobj\n"},
      {7, "7 0 obj\n<< /Type /StructElem /S /Document /P 6 0 R /K [8 0 R] >>\nendobj\n"},
      {8, "8 0 obj\n<< /Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K << /Type /MCR /Pg 3 0 R /MCID 0 >> >>\nendobj\n"},
      {9, "9 0 obj\n[8 0 R]\nendobj\n"}
    ], "/StructTreeRoot 6 0 R /MarkInfo << /Marked true >> /Lang (en-US) "); IO.puts("  tagged_accessible.pdf")

    # rotated_pages.pdf — 4 pages at 0, 90, 180, 270
    rots = [0, 90, 180, 270]
    rpages = Enum.with_index(rots, fn r, i ->
      cn = 6 + i*2; pn = 7 + i*2
      ct = "BT /F1 12 Tf 72 720 Td (R#{r}) Tj ET\n"
      [
        {cn, "#{cn} 0 obj\n<< /Length #{byte_size(ct)} >>\nstream\n#{ct}endstream\nendobj\n"},
        {pn, "#{pn} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate #{r} /Resources << /Font << /F1 3 0 R >> >> /Contents #{cn} 0 R >>\nendobj\n"}
      ]
    end) |> List.flatten()
    # kids inline below
    write(@pdf, "rotated_pages.pdf", assemble([
      {1, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"},
      {2, "2 0 obj\n<< /Type /Pages /Kids [#{Enum.map_join(rots, " ", fn r -> n = 7 + div(r, 90)*2; "#{n} 0 R" end)}] /Count 4 >>\nendobj\n"},
      {3, "3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"}
    ] ++ rpages))
    |> then(fn _ -> IO.puts("  rotated_pages.pdf") end)

    # cropped_nonzero_origin.pdf
    ct = "BT /F1 12 Tf 72 720 Td (Cropped) Tj ET\n"
    write(@pdf, "cropped_nonzero_origin.pdf", assemble([
      {1, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"},
      {2, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"},
      {3, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [72 72 540 720]\n   /Resources << /Font << /F1 4 0 R >> >>\n   /Contents 5 0 R >>\nendobj\n"},
      {4, "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"},
      {5, "5 0 obj\n<< /Length #{byte_size(ct)} >>\nstream\n#{ct}endstream\nendobj\n"}
    ]))
    |> then(fn _ -> IO.puts("  cropped_nonzero_origin.pdf") end)

    # 500_pages.pdf
    multi_page(500); IO.puts("  five_hundred_pages.pdf")

    # 50mb_images.pdf — 250 images at 1000x200 device-gray (~50 MB)
    big_image(250); IO.puts("  50mb_images.pdf")

    # corrupt_xref.pdf — build with deliberately wrong xref offset for object 5
    objs = [
      {1, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"},
      {2, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"},
      {3, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]\n   /Resources << /Font << /F1 4 0 R >> >>\n   /Contents 5 0 R >>\nendobj\n"},
      {4, "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"},
      {5, "5 0 obj\n<< /Length 0 >>\nstream\nendstream\nendobj\n"}
    ]
    hdr = "%PDF-1.7\n%\xFF\xFF\xFF\xFF\n"
    bdy = Enum.map_join(objs, fn {_, t} -> t end)
    {offs, _} = Enum.reduce(objs, {[], byte_size(hdr)}, fn {_, t}, {a, p} -> {[p | a], p + byte_size(t)} end)
    offs = Enum.reverse(offs)
    # Corrupt object 5's offset (index 4) to 9999999999
    offs = List.update_at(offs, 4, fn _ -> 9_999_999_999 end)
    cnt = length(objs) + 1
    xl = Enum.map(offs, fn o -> "#{pad(o)} 00000 n\n" end) |> Enum.join()
    xr = byte_size(hdr <> bdy)
    corrupted = hdr <> bdy <> "xref\n0 #{cnt}\n0000000000 65535 f \n#{xl}" <>
      "trailer\n<< /Size #{cnt} /Root 1 0 R >>\nstartxref\n#{xr}\n%%%%EOF\n"
    write(@pdf, "corrupt_xref.pdf", corrupted)
    IO.puts("  corrupt_xref.pdf")

    # linearized.pdf
    spdf("linearized.pdf", "Linearized"); IO.puts("  linearized.pdf")

    # pdf_a_2b.pdf
    md = ~s|<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/"><pdfaid:part>2</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>|
    spdf("pdf_a_2b.pdf", "PDF/A-2b", [
      {6, "6 0 obj\n<< /Type /Metadata /Subtype /XML /Length #{byte_size(md)} >>\nstream\n#{md}\nendstream\nendobj\n"},
      {7, "7 0 obj\n<< /Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB IEC61966-2.1) /Info (sRGB) >>\nendobj\n"}
    ], "/Metadata 6 0 R /OutputIntents [7 0 R] ")
    |> then(fn _ -> IO.puts("  pdf_a_2b.pdf") end)

    # with_attachments.pdf
    embed = "Hello from attachment!\n"
    spdf("with_attachments.pdf", "Attachment", [
      {6, "6 0 obj\n<< /Type /EmbeddedFile /Length #{byte_size(embed)} >>\nstream\n#{embed}endstream\nendobj\n"},
      {7, "7 0 obj\n<< /Type /Filespec /F (hello.txt) /EF << /F 6 0 R >> >>\nendobj\n"},
      {8, "8 0 obj\n<< /Type /Annot /Subtype /FileAttachment /FS 7 0 R /Rect [72 700 100 720] /Contents (Attached file) >>\nendobj\n"}
    ], "")
    |> then(fn _ -> IO.puts("  with_attachments.pdf") end)

    # with_layers_ocg.pdf
    spdf("with_layers_ocg.pdf", "OCG", [
      {6, "6 0 obj\n<< /Type /OCG /Name (Layer 1) >>\nendobj\n"},
      {7, "7 0 obj\n<< /Type /OCG /Name (Layer 2) >>\nendobj\n"}
    ], "/OCProperties << /OCGs [6 0 R 7 0 R] /D << /Order [6 0 R 7 0 R] /OFF [] >> >> ")
    |> then(fn _ -> IO.puts("  with_layers_ocg.pdf") end)

    # mixed_page_sizes.pdf
    sizes = [{"Letter", 612, 792}, {"A4", 595, 842}, {"Legal", 612, 1008}, {"Tabloid", 792, 1224}]
    mpages = Enum.with_index(sizes, fn {l, w, h}, i ->
      cn = 6 + i*2; pn = 7 + i*2
      ct = "BT /F1 12 Tf 72 720 Td (#{l}) Tj ET\n"
      [
        {cn, "#{cn} 0 obj\n<< /Length #{byte_size(ct)} >>\nstream\n#{ct}endstream\nendobj\n"},
        {pn, "#{pn} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{w} #{h}] /Resources << /Font << /F1 4 0 R >> >> /Contents #{cn} 0 R >>\nendobj\n"}
      ]
    end) |> List.flatten()
    mpage_ids = Enum.map_join(sizes |> Enum.with_index(), " ", fn {{_, _, _}, i} -> "#{7 + i*2} 0 R" end)
    write(@pdf, "mixed_page_sizes.pdf", assemble([
      {1, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"},
      {2, "2 0 obj\n<< /Type /Pages /Kids [#{mpage_ids}] /Count 4 >>\nendobj\n"},
      {3, "3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"}
    ] ++ mpages))
    |> then(fn _ -> IO.puts("  mixed_page_sizes.pdf") end)
  end

  # ── Office documents ─────────────────────────────────────────────

  defp office do
    # report.docx
    {:ok, {_, docx}} = :zip.create(~c"r.docx", [
      {~c"[Content_Types].xml", ~S|<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>|},
      {~c"_rels/.rels", ~S|<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>|},
      {~c"word/document.xml", ~S|<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Hello World - Report</w:t></w:r></w:p></w:body></w:document>|}
    ], [:memory])
    write(@off, "report.docx", docx)
    IO.puts("  report.docx")

    # budget.xlsx
    {:ok, {_, xlsx}} = :zip.create(~c"b.xlsx", [
      {~c"[Content_Types].xml", ~S|<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>|},
      {~c"_rels/.rels", ~S|<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>|},
      {~c"xl/workbook.xml", ~S|<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></sheets></workbook>|},
      {~c"xl/_rels/workbook.xml.rels", ~S|<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>|},
      {~c"xl/worksheets/sheet1.xml", ~S|<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Item</t></is></c><c r="B1" t="inlineStr"><is><t>Amount</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>Revenue</t></is></c><c r="B2" t="inlineStr"><is><t>$1000</t></is></c></row></sheetData></worksheet>|}
    ], [:memory])
    write(@off, "budget.xlsx", xlsx)
    IO.puts("  budget.xlsx")

    # deck.pptx
    {:ok, {_, pptx}} = :zip.create(~c"d.pptx", [
      {~c"[Content_Types].xml", ~S|<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/></Types>|},
      {~c"_rels/.rels", ~S|<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>|},
      {~c"ppt/presentation.xml", ~S|<?xml version="1.0"?><p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldIdLst><p:sldId id="256" r:id="rId1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/></p:presentation>|},
      {~c"ppt/_rels/presentation.xml.rels", ~S|<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>|},
      {~c"ppt/slides/slide1.xml", ~S|<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>Slide 1</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>|}
    ], [:memory])
    write(@off, "deck.pptx", pptx)
    IO.puts("  deck.pptx")

    # notes.odt
    {:ok, {_, odt}} = :zip.create(~c"n.odt", [
      {~c"mimetype", "application/vnd.oasis.opendocument.text"},
      {~c"content.xml", ~S|<?xml version="1.0"?><office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:p>Notes</text:p></office:text></office:body></office:document>|},
      {~c"META-INF/manifest.xml", ~S|<?xml version="1.0"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>|}
    ], [:memory])
    write(@off, "notes.odt", odt)
    IO.puts("  notes.odt")

    # letter.rtf
    write(@off, "letter.rtf", "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Courier New;}}\n\\f0\\fs24 Dear Sir or Madam,\\par \\par This is a letter.\\par \\par Sincerely,\\par Author\\par\n}")
    IO.puts("  letter.rtf")
  end

  # ── Image ────────────────────────────────────────────────────────

  defp images do
    # Minimal 1x1 white PNG
    write(@img, "white_1x1.png", <<137,80,78,71,13,10,26,10,
      0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,144,119,83,222,
      0,0,0,17,73,68,65,84,120,156,99,248,207,192,0,0,0,255,0,1,8,0,0,20,0,0,0,0,128,0,
      0,0,0,0,73,69,78,68,174,66,96,130>>)
    IO.puts("  white_1x1.png")

    # 2x1 white RGBA — built manually as valid PNG
    # Filter byte (0-none) + RGB bytes per pixel, raw unfiltered = 7 bytes
    # Compressed with zlib (minimal overhead via :zlib gemerate)
    raw = <<0, 255, 255, 255, 255, 255, 255>>
    z = :zlib.open()
    :zlib.deflateInit(z)
    compressed = IO.iodata_to_binary(:zlib.deflate(z, raw, :finish))
    :zlib.deflateEnd(z)
    :zlib.close(z)
    crc32 = &:erlang.crc32(&1)
    len = byte_size(compressed)
    idat = <<len::32, 73, 68, 65, 84, compressed::binary, crc32.("IDAT" <> compressed)::32>>
    iend = <<0, 0, 0, 0, 73, 69, 78, 68, crc32.("IEND")::32>>
    png2 = <<137, 80, 78, 71, 13, 10, 26, 10,
      0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 1, 8, 2, 0, 0, 0, 181, 168, 131, 24,
      idat::binary, iend::binary>>
    write(@img, "white_2x1.png", png2)
    IO.puts("  white_2x1.png")
  end
end

GenerateFixtures.run()
