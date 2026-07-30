defmodule Quire.Office.Writer.Docx do
  @moduledoc ~S"""
  Renders a `Quire.Office.Layout.t()` to a DOCX (OOXML) binary.

  Best for text-based PDFs. Formatting fidelity is best-effort.

  Produces a valid OOXML package — a ZIP archive containing XML files
  conforming to ECMA-376.

  ## Supported blocks

    * `{:paragraph, text}` → `<w:p>` with `<w:r><w:t>`
    * `{:heading, text, level}` → `<w:p>` with heading style
    * `{:table, headers, rows}` → `<w:tbl>`
    * `{:list, items, ordered}` → `<w:p>` with `<w:numPr>`
    * `{:image, bytes, alt, ext}` → embedded in `word/media/` with rId

  Conversion report notes from the layout are appended as a section at
  the end of the document body.
  """

  @behaviour Quire.Office.Writer

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  # ── Behaviour callbacks ─────────────────────────────────────────────────

  @doc """
  Write layout to DOCX binary.

  ## Examples

      {:ok, docx_binary} = Quire.Office.Writer.Docx.write(layout, :docx, [])
  """
  @spec write(Layout.t(), :docx, keyword()) :: {:ok, binary()}
  def write(layout, format, opts \\ [])

  def write(%Layout{} = layout, :docx, _opts) do
    init_state = %{media: [], next_media_id: 1}

    {sections_lines, state} =
      Enum.reduce(layout.sections, {[], init_state}, fn section, {acc, st} ->
        {xml, st2} = render_section(section, st)
        {[xml | acc], st2}
      end)

    sections_xml = Enum.reverse(sections_lines) |> Enum.join("\n")

    title_xml =
      if layout.title && layout.title != "" do
        ~s[<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>#{xml_escape(layout.title)}</w:t></w:r></w:p>]
      else
        ""
      end

    report_xml = render_report(layout.report)

    body_xml = ~s[<w:body>\n#{title_xml}\n#{sections_xml}\n#{report_xml}\n</w:body>]
    doc_xml = document_xml(body_xml)
    {:ok, build_zip(doc_xml, state)}
  end

  def write(%Layout{}, format, _opts) do
    {:error, "Unsupported format: #{inspect(format)}"}
  end

  @doc "Best for text-based PDFs. Formatting fidelity is best-effort."
  @spec supported_formats() :: [:docx]
  def supported_formats, do: [:docx]

  # ── Section rendering ───────────────────────────────────────────────────

  defp render_section(%Section{type: _type, title: s_title, blocks: blocks}, state) do
    title_xml =
      if s_title && s_title != "" do
        ~s[<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>#{xml_escape(s_title)}</w:t></w:r></w:p>]
      else
        ""
      end

    {blocks_xml, state} =
      Enum.reduce(blocks, {[], state}, fn block, {acc, st} ->
        {xml, st2} = render_block(block, st)
        {[xml | acc], st2}
      end)

    {title_xml <> (Enum.reverse(blocks_xml) |> Enum.join("\n")), state}
  end

  # ── Block rendering ─────────────────────────────────────────────────────

  defp render_block({:paragraph, text}, state) do
    {~s[<w:p><w:r><w:t>#{xml_escape(text)}</w:t></w:r></w:p>], state}
  end

  defp render_block({:heading, text, level}, state) do
    l = min(max(level, 1), 6)
    style = "Heading#{l}"

    {~s[<w:p><w:pPr><w:pStyle w:val="#{style}"/></w:pPr><w:r><w:t>#{xml_escape(text)}</w:t></w:r></w:p>],
     state}
  end

  defp render_block({:table, headers, rows}, state) do
    {render_table_block(headers, rows), state}
  end

  defp render_block({:list, items, ordered}, state) do
    num_id = if ordered, do: 1, else: 2

    items_xml =
      Enum.map_join(items, "\n", fn item ->
        ~s[<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="#{num_id}"/></w:numPr></w:pPr><w:r><w:t>#{xml_escape(item)}</w:t></w:r></w:p>]
      end)

    {items_xml, state}
  end

  defp render_block({:image, bytes, alt, ext}, state) do
    media_id = state.next_media_id
    r_id = media_id + 2
    filename = "image#{media_id}.#{ext}"
    state = %{state | media: state.media ++ [{filename, bytes}], next_media_id: media_id + 1}

    cx = 4_800_000
    cy = 3_600_000

    xml = ~s"""
    <w:p>
      <w:r>
        <w:drawing>
          <wp:inline distT="0" distB="0" distL="0" distR="0" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
            <wp:extent cx="#{cx}" cy="#{cy}"/>
            <wp:effectExtent l="0" t="0" r="0" b="0"/>
            <wp:docPr id="#{media_id}" name="#{xml_escape(alt)}" descr="#{xml_escape(alt)}"/>
            <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
              <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
                  <pic:blipFill>
                    <a:blip r:embed="rId#{r_id}"/>
                  </pic:blipFill>
                  <pic:spPr>
                    <a:xfrm>
                      <a:off x="0" y="0"/>
                      <a:ext cx="#{cx}" cy="#{cy}"/>
                    </a:xfrm>
                    <a:prstGeom prst="rect"/>
                  </pic:spPr>
                </pic:pic>
              </a:graphicData>
            </a:graphic>
          </wp:inline>
        </w:drawing>
      </w:r>
    </w:p>
    """

    {xml, state}
  end

  defp render_block(_unknown, state) do
    {"", state}
  end

  # ── Table rendering ─────────────────────────────────────────────────────

  defp render_table_block(headers, rows) do
    col_count = max(length(headers), if(rows != [], do: length(hd(rows)), else: 1))

    grid =
      Enum.map_join(1..col_count, "\n", fn _ ->
        ~s[<w:gridCol w:w="2000"/>]
      end)

    header_row =
      if headers != [] do
        cells =
          Enum.map_join(headers, "\n", fn h ->
            ~s[<w:tc><w:p><w:r><w:t>#{xml_escape(h)}</w:t></w:r></w:p></w:tc>]
          end)

        ~s[<w:tr><w:trPr><w:tblHeader/></w:trPr>#{cells}</w:tr>]
      else
        ""
      end

    data_rows =
      Enum.map_join(rows, "\n", fn row ->
        cells =
          Enum.map_join(row, "\n", fn cell ->
            ~s[<w:tc><w:p><w:r><w:t>#{xml_escape(cell)}</w:t></w:r></w:p></w:tc>]
          end)

        ~s[<w:tr>#{cells}</w:tr>]
      end)

    ~s"""
    <w:tbl>
      <w:tblPr>
        <w:tblW w:w="5000" w:type="dxa"/>
        <w:tblBorders>
          <w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>
          <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>
          <w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>
          <w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>
          <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>
          <w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>
        </w:tblBorders>
      </w:tblPr>
      <w:tblGrid>
        #{grid}
      </w:tblGrid>
      #{header_row}
      #{data_rows}
    </w:tbl>
    """
  end

  # ── Report rendering ────────────────────────────────────────────────────

  defp render_report([]), do: ""

  defp render_report(notes) do
    items =
      Enum.map_join(notes, "\n", fn note ->
        msg = xml_escape("#{note.level}: #{note.message} (#{note.source})")
        ~s[<w:p><w:pPr><w:pStyle w:val="Normal"/></w:pPr><w:r><w:t>#{msg}</w:t></w:r></w:p>]
      end)

    ~s[<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Conversion Report</w:t></w:r></w:p>] <>
      items
  end

  # ── Document wrapper ────────────────────────────────────────────────────

  defp document_xml(body) do
    ~s[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>] <>
      ~s[<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"] <>
      ~s[ xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">] <>
      body <>
      ~s[</w:document>]
  end

  # ── ZIP assembly ────────────────────────────────────────────────────────

  defp build_zip(doc_xml, state) do
    media_rels =
      Enum.with_index(state.media, 3)
      |> Enum.map(fn {{filename, _bytes}, r_id} ->
        ~s[<Relationship Id="rId#{r_id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/#{filename}"/>]
      end)

    media_rels_xml = Enum.join(media_rels, "\n")

    doc_rels_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
      #{media_rels_xml}
    </Relationships>
    """

    content_types_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Default Extension="png" ContentType="image/png"/>
      <Default Extension="jpg" ContentType="image/jpeg"/>
      <Default Extension="jpeg" ContentType="image/jpeg"/>
      <Default Extension="gif" ContentType="image/gif"/>
      <Default Extension="bmp" ContentType="image/bmp"/>
      <Default Extension="tiff" ContentType="image/tiff"/>
      <Default Extension="svg" ContentType="image/svg+xml"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
      <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
      <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
      <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
    </Types>
    """

    rels_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
    </Relationships>
    """

    styles_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:docDefaults>
        <w:rPrDefault>
          <w:rPr>
            <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/>
            <w:sz w:val="22"/>
            <w:szCs w:val="22"/>
            <w:lang w:val="en-US"/>
          </w:rPr>
        </w:rPrDefault>
      </w:docDefaults>
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
        <w:name w:val="Normal"/>
        <w:qFormat/>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Title">
        <w:name w:val="Title"/>
        <w:basedOn w:val="Normal"/>
        <w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr>
        <w:rPr><w:sz w:val="44"/><w:b/></w:rPr>
      </w:style>
      #{heading_styles_xml()}
    </w:styles>
    """

    numbering_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:abstractNum w:abstractNumId="0">
        <w:nsid w:val="00000001"/>
        <w:multiLevelType w:val="hybridMultilevel"/>
        <w:lvl w:ilvl="0">
          <w:start w:val="1"/>
          <w:numFmt w:val="decimal"/>
          <w:lvlText w:val="%1."/>
          <w:lvlJc w:val="left"/>
          <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>
        </w:lvl>
      </w:abstractNum>
      <w:abstractNum w:abstractNumId="1">
        <w:nsid w:val="00000002"/>
        <w:multiLevelType w:val="hybridMultilevel"/>
        <w:lvl w:ilvl="0">
          <w:start w:val="1"/>
          <w:numFmt w:val="bullet"/>
          <w:lvlText w:val="\u2022"/>
          <w:lvlJc w:val="left"/>
          <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>
        </w:lvl>
      </w:abstractNum>
      <w:num w:numId="1">
        <w:abstractNumId w:val="0"/>
      </w:num>
      <w:num w:numId="2">
        <w:abstractNumId w:val="1"/>
      </w:num>
    </w:numbering>
    """

    docProps_core_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                       xmlns:dc="http://purl.org/dc/elements/1.1/"
                       xmlns:dcterms="http://purl.org/dc/terms/"
                       xmlns:dcmitype="http://purl.org/dc/dcmitype/"
                       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <dc:creator>Oh My Pi</dc:creator>
      <dcterms:created xsi:type="dcterms:W3CDTF">#{DateTime.utc_now() |> DateTime.to_iso8601()}</dcterms:created>
    </cp:coreProperties>
    """

    docProps_app_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
                xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
      <Application>Oh My Pi</Application>
      <DocSecurity>0</DocSecurity>
      <Lines>1</Lines>
      <Paragraphs>1</Paragraphs>
      <ScaleCrop>false</ScaleCrop>
      <LinksUpToDate>false</LinksUpToDate>
      <SharedDoc>false</SharedDoc>
      <HyperlinksChanged>false</HyperlinksChanged>
      <AppVersion>0.1.0</AppVersion>
    </Properties>
    """

    media_entries =
      Enum.map(state.media, fn {filename, bytes} ->
        {~c"word/media/#{filename}", bytes}
      end)

    zip_entries =
      [
        {~c"[Content_Types].xml", content_types_xml},
        {~c"_rels/.rels", rels_xml},
        {~c"word/document.xml", doc_xml},
        {~c"word/_rels/document.xml.rels", doc_rels_xml},
        {~c"word/styles.xml", styles_xml},
        {~c"word/numbering.xml", numbering_xml},
        {~c"docProps/core.xml", docProps_core_xml},
        {~c"docProps/app.xml", docProps_app_xml}
      ] ++ media_entries

    {:ok, {_name, zip_binary}} = :zip.create(~c"document.docx", zip_entries, [:memory])
    zip_binary
  end

  # ── Heading style definitions ──────────────────────────────────────────

  defp heading_styles_xml do
    [
      {1, 40, 240, 120},
      {2, 36, 200, 100},
      {3, 32, 160, 80},
      {4, 28, nil, nil},
      {5, 24, nil, nil},
      {6, 22, nil, nil}
    ]
    |> Enum.map_join("\n", fn {lvl, sz, sp_before, sp_after} ->
      spacing =
        if sp_before do
          "\n        <w:pPr><w:spacing w:before=\"#{sp_before}\" w:after=\"#{sp_after}\"/></w:pPr>"
        else
          ""
        end

      ~s"""
      <w:style w:type="paragraph" w:styleId="Heading#{lvl}">
        <w:name w:val="heading #{lvl}"/>
        <w:basedOn w:val="Normal"/>
        #{spacing}
        <w:rPr><w:sz w:val="#{sz}"/><w:szCs w:val="#{sz}"/><w:b/></w:rPr>
      </w:style>
      """
    end)
  end

  # ── XML escaping ────────────────────────────────────────────────────────

  defp xml_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s["], "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp xml_escape(nil), do: ""
end
