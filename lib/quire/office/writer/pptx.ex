defmodule Quire.Office.Writer.Pptx do
  @moduledoc ~S"""
  Renders a `Quire.Office.Layout.t()` to a PPTX (OOXML) binary.

  Best for text-based PDFs. Formatting fidelity is best-effort.

  Produces a valid OOXML package — a ZIP archive containing XML files
  conforming to ECMA-376.

  Each section becomes a slide. Blocks are positioned as text boxes:

    * `{:paragraph, text}` → `<a:p>` in a text box
    * `{:heading, text, level}` → `<a:p>` with larger font size
    * `{:table, headers, rows}` → `<a:tbl>` table
    * `{:list, items, ordered}` → `<a:p>` with bulleted / numbered text
    * `{:image, bytes, alt, ext}` → embedded in `ppt/media/` with rId
  """

  @behaviour Quire.Office.Writer

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  # ── Behaviour callbacks ─────────────────────────────────────────────────

  @doc """
  Write layout to PPTX binary.

  ## Examples

      {:ok, pptx_binary} = Quire.Office.Writer.Pptx.write(layout, :pptx, [])
  """
  @spec write(Layout.t(), :pptx, keyword()) :: {:ok, binary()}
  def write(%Layout{} = layout, :pptx, _opts \\ []) do
    init_state = %{media: [], next_media_id: 1}

    {slides_xmls, state} =
      Enum.reduce(layout.sections, {[], init_state}, fn section, {acc, st} ->
        {slide_xml, st2} = render_slide(section, st, acc)
        {[slide_xml | acc], st2}
      end)

    slides = Enum.reverse(slides_xmls)
    {:ok, build_zip(slides, state)}
  end

  @doc "Best for text-based PDFs. Formatting fidelity is best-effort."
  @spec supported_formats() :: [:pptx]
  def supported_formats, do: [:pptx]

  # ── Slide rendering ─────────────────────────────────────────────────────

  defp render_slide(%Section{type: _type, title: title, blocks: blocks}, state, rendered_so_far) do
    slide_num = length(rendered_so_far) + 1
    {blocks_xml, state} = Enum.reduce(blocks, {[], state}, &render_block_pptx/2)

    title_xml =
      if title && title != "" do
        ~s"""
        <p:sp>
          <p:nvSpPr>
            <p:cNvPr id="1" name="Title"/>
            <p:cNvSpPr txBox="1"/>
            <p:nvPr/>
          </p:nvSpPr>
          <p:spPr/>
          <p:txBody>
            <a:bodyPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"/>
            <a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
              <a:r>
                <a:rPr sz="3600" b="1"/>
                <a:t>#{xml_escape(title)}</a:t>
              </a:r>
            </a:p>
          </p:txBody>
        </p:sp>
        """
      else
        ""
      end

    slide_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
           xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
           xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <p:cSld name="Slide #{slide_num}">
        <p:spTree>
          <p:nvGrpSpPr>
            <p:cNvPr id="0" name=""/>
            <p:cNvGrpSpPr/>
            <p:nvPr/>
          </p:nvGrpSpPr>
          <p:grpSpPr/>
          #{title_xml}
          #{Enum.reverse(blocks_xml) |> Enum.join("\n")}
        </p:spTree>
      </p:cSld>
      <p:clrMapOvr>
        <a:masterClrMapping/>
      </p:clrMapOvr>
    </p:sld>
    """

    {slide_xml, state}
  end

  # ── Block rendering for PPTX ────────────────────────────────────────────

  defp render_block_pptx({:paragraph, text}, {acc, state}) do
    xml = ~s"""
    <p:sp>
      <p:nvSpPr>
        <p:cNvPr id="0" name="TextBox"/>
        <p:cNvSpPr txBox="1"/>
        <p:nvPr/>
      </p:nvSpPr>
      <p:spPr>
        <a:xfrm xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <a:off x="457200" y="457200"/>
          <a:ext cx="8229600" cy="342900"/>
        </a:xfrm>
      </p:spPr>
      <p:txBody>
        <a:bodyPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"/>
        <a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <a:r>
            <a:rPr sz="1800"/>
            <a:t>#{xml_escape(text)}</a:t>
          </a:r>
        </a:p>
      </p:txBody>
    </p:sp>
    """

    {[xml | acc], state}
  end

  defp render_block_pptx({:heading, text, level}, {acc, state}) do
    sz = heading_size_pptx(level)

    xml = ~s"""
    <p:sp>
      <p:nvSpPr>
        <p:cNvPr id="0" name="Heading"/>
        <p:cNvSpPr txBox="1"/>
        <p:nvPr/>
      </p:nvSpPr>
      <p:spPr>
        <a:xfrm xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <a:off x="457200" y="457200"/>
          <a:ext cx="8229600" cy="685800"/>
        </a:xfrm>
      </p:spPr>
      <p:txBody>
        <a:bodyPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"/>
        <a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <a:r>
            <a:rPr sz="#{sz}" b="1"/>
            <a:t>#{xml_escape(text)}</a:t>
          </a:r>
        </a:p>
      </p:txBody>
    </p:sp>
    """

    {[xml | acc], state}
  end

  defp render_block_pptx({:table, headers, rows}, {acc, state}) do
    col_count = max(length(headers), if(rows != [], do: length(hd(rows)), else: 1))

    # Build table grid and rows
    grid =
      Enum.map_join(1..col_count, "\n", fn _ ->
        ~s[<a:gridCol w="#{div(8_229_600, col_count)}"/>]
      end)

    header_xml =
      if headers != [] do
        cells =
          Enum.map_join(headers, "\n", fn h ->
            ~s[<a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:rPr b="1"/><a:t>#{xml_escape(h)}</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>]
          end)

        ~s[<a:tr h="370840">#{cells}</a:tr>]
      else
        ""
      end

    body_rows =
      Enum.map_join(rows, "\n", fn row ->
        cells =
          Enum.map_join(row, "\n", fn cell ->
            ~s[<a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>#{xml_escape(cell)}</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>]
          end)

        ~s[<a:tr h="370840">#{cells}</a:tr>]
      end)

    xml = ~s"""
    <p:graphicFrame>
      <p:nvGraphicFramePr>
        <p:cNvPr id="0" name="Table"/>
        <p:cNvGraphicFramePr>
          <a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noGrp="1"/>
        </p:cNvGraphicFramePr>
        <p:nvPr/>
      </p:nvGraphicFramePr>
      <p:xfrm>
        <a:off x="457200" y="457200"/>
        <a:ext cx="8229600" cy="#{max(1, length(rows) + if(headers != [], do: 1, else: 0)) * 370_840}"/>
      </p:xfrm>
      <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
        <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">
          <a:tbl>
            <a:tblPr/>
            <a:tblGrid>#{grid}</a:tblGrid>
            #{header_xml}
            #{body_rows}
          </a:tbl>
        </a:graphicData>
      </a:graphic>
    </p:graphicFrame>
    """

    {[xml | acc], state}
  end

  defp render_block_pptx({:list, items, ordered}, {acc, state}) do
    items_xml =
      Enum.map_join(items, "\n", fn item ->
        bu_xml =
          if ordered do
            ~s[<a:buAutoNum type="arabicPeriod"/>]
          else
            ~s[<a:buChar char="\u2022"/>]
          end

        ~s"""
        <p:sp>
          <p:nvSpPr>
            <p:cNvPr id="0" name="ListItem"/>
            <p:cNvSpPr txBox="1"/>
            <p:nvPr/>
          </p:nvSpPr>
          <p:spPr>
            <a:xfrm xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
              <a:off x="914400" y="274320"/>
              <a:ext cx="7772400" cy="342900"/>
            </a:xfrm>
          </p:spPr>
          <p:txBody>
            <a:bodyPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"/>
            <a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" marL="342900">
              <a:pPr marL="342900" indent="-342900">
                #{bu_xml}
              </a:pPr>
              <a:r>
                <a:rPr sz="1800"/>
                <a:t>#{xml_escape(item)}</a:t>
              </a:r>
            </a:p>
          </p:txBody>
        </p:sp>
        """
      end)

    {[items_xml | acc], state}
  end

  defp render_block_pptx({:image, bytes, alt, ext}, {acc, state}) do
    media_id = state.next_media_id
    filename = "image#{media_id}.#{ext}"
    # rId1 is slideLayout
    r_id = media_id + 1
    state = %{state | media: state.media ++ [{filename, bytes}], next_media_id: media_id + 1}

    # Image EMU dimensions — default ~4 x 3 inches
    cx = 4_800_000
    cy = 3_600_000

    xml = ~s"""
    <p:pic>
      <p:nvPicPr>
        <p:cNvPr id="#{media_id}" name="#{xml_escape(alt)}" descr="#{xml_escape(alt)}"/>
        <p:cNvPicPr/>
        <p:nvPr/>
      </p:nvPicPr>
      <p:blipFill>
        <a:blip xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" r:embed="rId#{r_id}"/>
        <a:stretch xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <a:fillRect/>
        </a:stretch>
      </p:blipFill>
      <p:spPr>
        <a:xfrm xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <a:off x="685800" y="457200"/>
          <a:ext cx="#{cx}" cy="#{cy}"/>
        </a:xfrm>
        <a:prstGeom prst="rect"/>
      </p:spPr>
    </p:pic>
    """

    {[xml | acc], state}
  end

  defp render_block_pptx(_unknown, {acc, state}) do
    # Silently skip unknown block types
    {acc, state}
  end

  # ── Heading sizes in hundredths of a point (PPTX) ──────────────────────

  defp heading_size_pptx(level) when level <= 1, do: 4400
  defp heading_size_pptx(2), do: 3600
  defp heading_size_pptx(3), do: 2800
  defp heading_size_pptx(4), do: 2400
  defp heading_size_pptx(5), do: 2000
  defp heading_size_pptx(_), do: 1800

  # ── ZIP assembly ────────────────────────────────────────────────────────

  defp build_zip(slides, state) do
    slide_count = length(slides)

    # Build per-slide relationships — include all images in every slide rels
    # for simplicity; PowerPoint will ignore unused relationships.
    media_rels_all =
      state.media
      |> Enum.with_index(2)
      |> Enum.map(fn {{filename, _bytes}, r_id} ->
        ~s[<Relationship Id="rId#{r_id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/#{filename}"/>]
      end)
      |> Enum.join("
")

    slide_rels =
      Enum.map(1..slide_count, fn _i ->
        base =
          ~s[<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>]

        entries =
          if media_rels_all != "" do
            base <> "
" <> media_rels_all
          else
            base
          end

        ~s"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          #{entries}
        </Relationships>
        """
      end)

    # ── content_types.xml ──
    slide_overrides =
      Enum.map_join(1..slide_count, "\n", fn i ->
        ~s[<Override PartName="/ppt/slides/slide#{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>]
      end)

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
      <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
      <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
      <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
      <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
      #{slide_overrides}
      <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
      <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
    </Types>
    """

    # ── _rels/.rels ──
    rels_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
    </Relationships>
    """

    # ── ppt/presentation.xml ──
    slide_id_entries =
      Enum.map_join(1..slide_count, "\n", fn i ->
        ~s[<p:sldId id="#{256 + i}" r:id="rId#{i + 1}"/>]
      end)

    presentation_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <p:sldMasterIdLst>
        <p:sldMasterId id="2147483648" r:id="rId1"/>
      </p:sldMasterIdLst>
      <p:sldIdLst>
        #{slide_id_entries}
      </p:sldIdLst>
      <p:sldSz cx="9144000" cy="6858000"/>
      <p:notesSz cx="6858000" cy="9144000"/>
    </p:presentation>
    """

    # ── ppt/_rels/presentation.xml.rels ──
    slide_rel_entries =
      Enum.map_join(1..slide_count, "\n", fn i ->
        ~s[<Relationship Id="rId#{i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide#{i}.xml"/>]
      end)

    pres_rels_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
      #{slide_rel_entries}
    </Relationships>
    """

    # ── ppt/slideMasters/slideMaster1.xml ──
    slide_master_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldMaster xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <p:cSld name="SlideMaster">
        <p:bg>
          <p:bgPr>
            <a:solidFill>
              <a:schemeClr val="bg1"/>
            </a:solidFill>
          </p:bgPr>
        </p:bg>
        <p:spTree>
          <p:nvGrpSpPr>
            <p:cNvPr id="0" name=""/>
            <p:cNvGrpSpPr/>
            <p:nvPr/>
          </p:nvGrpSpPr>
          <p:grpSpPr/>
        </p:spTree>
      </p:cSld>
      <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
      <p:sldLayoutIdLst>
        <p:sldLayoutId id="2147483649" r:id="rId1"/>
      </p:sldLayoutIdLst>
    </p:sldMaster>
    """

    # ── ppt/slideMasters/_rels/slideMaster1.xml.rels ──
    sm_rels_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
    </Relationships>
    """

    # ── ppt/slideLayouts/slideLayout1.xml ──
    slide_layout_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldLayout xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                 type="blank">
      <p:cSld name="Blank">
        <p:spTree>
          <p:nvGrpSpPr>
            <p:cNvPr id="0" name=""/>
            <p:cNvGrpSpPr/>
            <p:nvPr/>
          </p:nvGrpSpPr>
          <p:grpSpPr/>
        </p:spTree>
      </p:cSld>
      <p:clrMapOvr>
        <a:masterClrMapping/>
      </p:clrMapOvr>
    </p:sldLayout>
    """

    # ── ppt/slideLayouts/_rels/slideLayout1.xml.rels ──
    sl_rels_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
    </Relationships>
    """

    # ── ppt/theme/theme1.xml ──
    theme_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Default">
      <a:themeElements>
        <a:clrScheme name="Default">
          <a:dk1><a:srgbClr val="000000"/></a:dk1>
          <a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
          <a:dk2><a:srgbClr val="44546A"/></a:dk2>
          <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>
          <a:accent1><a:srgbClr val="4472C4"/></a:accent1>
          <a:accent2><a:srgbClr val="ED7D31"/></a:accent2>
          <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>
          <a:accent4><a:srgbClr val="FFC000"/></a:accent4>
          <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>
          <a:accent6><a:srgbClr val="70AD47"/></a:accent6>
          <a:hlink><a:srgbClr val="0563C1"/></a:hlink>
          <a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
        </a:clrScheme>
        <a:fontScheme name="Default">
          <a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
          <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>
        </a:fontScheme>
        <a:fmtScheme name="Default">
          <a:fillStyleLst>
            <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
            <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
            <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
          </a:fillStyleLst>
          <a:lnStyleLst>
            <a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
            <a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
            <a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
          </a:lnStyleLst>
          <a:effectStyleLst>
            <a:effectStyle><a:effectLst/></a:effectStyle>
            <a:effectStyle><a:effectLst/></a:effectStyle>
            <a:effectStyle><a:effectLst/></a:effectStyle>
          </a:effectStyleLst>
          <a:bgFillStyleLst>
            <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
            <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
            <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
          </a:bgFillStyleLst>
        </a:fmtScheme>
      </a:themeElements>
    </a:theme>
    """

    # ── docProps ──
    docProps_core_xml = ~s"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                       xmlns:dc="http://purl.org/dc/elements/1.1/"
                       xmlns:dcterms="http://purl.org/dc/terms/"
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
      <AppVersion>0.1.0</AppVersion>
      <SlideCount>#{slide_count}</SlideCount>
    </Properties>
    """

    # ── Assemble ZIP entries ──
    slide_entries =
      Enum.zip(1..slide_count, slides)
      |> Enum.flat_map(fn {i, xml} ->
        rel_idx = i - 1

        [
          {~c"ppt/slides/slide#{i}.xml", xml},
          {~c"ppt/slides/_rels/slide#{i}.xml.rels", Enum.at(slide_rels, rel_idx)}
        ]
      end)

    media_entries =
      Enum.map(state.media, fn {filename, bytes} ->
        {~c"ppt/media/#{filename}", bytes}
      end)

    zip_entries =
      [
        {~c"[Content_Types].xml", content_types_xml},
        {~c"_rels/.rels", rels_xml},
        {~c"ppt/presentation.xml", presentation_xml},
        {~c"ppt/_rels/presentation.xml.rels", pres_rels_xml},
        {~c"ppt/slideMasters/slideMaster1.xml", slide_master_xml},
        {~c"ppt/slideMasters/_rels/slideMaster1.xml.rels", sm_rels_xml},
        {~c"ppt/slideLayouts/slideLayout1.xml", slide_layout_xml},
        {~c"ppt/slideLayouts/_rels/slideLayout1.xml.rels", sl_rels_xml},
        {~c"ppt/theme/theme1.xml", theme_xml},
        {~c"docProps/core.xml", docProps_core_xml},
        {~c"docProps/app.xml", docProps_app_xml}
      ] ++ slide_entries ++ media_entries

    {:ok, {_name, zip_binary}} = :zip.create(~c"document.pptx", zip_entries, [:memory])
    zip_binary
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
