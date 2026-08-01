defmodule Quire.Test.SevenFieldForm do
  @moduledoc """
  Authors a PDF form that exercises **every field type the app supports**
  (§9.8 Forms): text, checkbox, radio, combo box, list box, push button and
  signature.

  This is the fixture backing the Acrobat + Chrome compatibility test
  (T-126 / `pdf-mh2w`). It is deliberately written through the low-level
  `Quire.Pdf` object model (the same primitives `Quire.Pdf.AcroForm` builds
  on) so the resulting PDF is ordinary ISO 32000 AcroForm and opens in
  Acrobat / Chrome's built-in PDFium viewer as well as the app's own engine.

  The authored field order (the order of `/AcroForm /Fields`) **is the tab
  order**, so the test can assert tab order trivially by comparing it to the
  order the fields were authored in.

  ## Field rows (in authored / tab order)

    | # | Field            | /FT  | /Ff                       | semantics            |
    |---|------------------|------|---------------------------|----------------------|
    | 0 | first_name       | Tx   | —                         | text field           |
    | 1 | agree_checkbox   | Btn  | checkbox (no flag)        | check box            |
    | 2 | option_radio     | Btn  | 1<<15 radio (32768)       | radio button         |
    | 3 | country_combo    | Ch   | 1<<17 combo (131072) + 1  | combo box            |
    | 4 | fruit_list       | Ch   | no combo flag             | list box             |
    | 5 | submit_btn       | Btn  | 1<<16 pushbutton (65536)  | push / submit button |
    | 6 | sign_field       | Sig  | —                         | signature            |

  The signature field lives on a **rotated + cropped** page variant when
  requested via `build_rotated_cropped_sig/1` (Gate 7): a page whose /MediaBox
  is landscape and whose /CropBox has a non-zero origin, so the widget must
  survive a CropBox / subject transform plus save + reload.
  """

  alias Quire.Pdf

  @page_width 595.0
  @page_height 842.0

  @doc """
  The list of `{kind, name, rect}` field specs in authored (tab) order.

  Rectangles are `[llx, lly, urx, ury]` in PDF user space (points), y-up,
  laid out top-to-bottom on an A4 portrait page.
  """
  @spec specs() :: [{atom(), String.t(), [number()]}]
  def specs do
    [
      {:text, "first_name", [72, 740, 280, 760]},
      {:checkbox, "agree_checkbox", [72, 700, 92, 720]},
      {:radio, "option_radio", [72, 660, 92, 680]},
      {:combo, "country_combo", [72, 620, 250, 640]},
      {:list, "fruit_list", [72, 580, 250, 600]},
      {:button, "submit_btn", [72, 540, 180, 560]},
      {:signature, "sign_field", [300, 460, 520, 580]}
    ]
  end

  @doc """
  Returns the field kinds present, in authored order: `[:text, :checkbox,
  :radio, :combo, :list, :button, :signature]` — one of each supported type.
  """
  @spec kinds() :: [atom()]
  def kinds, do: Enum.map(specs(), fn {k, _, _} -> k end)

  @doc """
  Names of the fields, in authored (tab) order.
  """
  @spec names() :: [String.t()]
  def names, do: Enum.map(specs(), fn {_, n, _} -> n end)

  @doc """
  Build a single-page A4 PDF with every field type present and the `/AcroForm
  /Fields` array in the authored (tab) order.

  Returns the PDF binary. The byte stream is deterministic for a given build
  but callers should treat it as an opaque artifact and re-author rather than
  string-match.
  """
  @spec build() :: binary()
  def build do
    {:ok, qdoc} = blank()
    refs = write_fields(qdoc, specs())
    _ = refs
    save(qdoc)
  end

  @doc """
  Build the Gate 7 fixture: a signature field on a **rotated and cropped**
  page. The page is landscape (MediaBox 842 x 595) with a non-zero-origin
  CropBox `[60, 60, 762, 555]` and a 90° /Rotate, carrying a signature field
  plus a short text field.

  Returns `{:ok, binary()}`. The fixture is designed to be saved, reloaded
  and re-read, proving the signature widget survives save/reload.
  """
  @spec build_rotated_cropped_sig() :: {:ok, binary()}
  def build_rotated_cropped_sig do
    {:ok, qdoc} = blank_landscape_cropped()

    specs = [
      {:signature, "sign_field", [420, 300, 560, 440]},
      {:text, "notary_name", [120, 300, 320, 320]}
    ]

    refs = write_fields(qdoc, specs)
    _ = refs
    {:ok, save(qdoc)}
  end

  # ── Low-level construction ────────────────────────────────────────────────

  defp blank() do
    {:ok, doc} = ExPdfium.new()
    {:ok, doc} = ExPdfium.add_page(doc, {@page_width, @page_height})
    {:ok, bytes} = ExPdfium.save_to_bytes(doc)
    Pdf.open(bytes)
  end

  # Landscape page (842x595) with CropBox [60 60 762 555] and /Rotate 90.
  defp blank_landscape_cropped() do
    {:ok, doc} = ExPdfium.new()
    {:ok, doc} = ExPdfium.add_page(doc, {@page_height, @page_width})
    {:ok, bytes} = ExPdfium.save_to_bytes(doc)
    {:ok, qdoc} = Pdf.open(bytes)

    {:ok, page_obj} = first_page_ref(qdoc)

    {:ok, page} = Pdf.get_object(qdoc, page_obj)

    patched =
      page
      |> Map.put("/MediaBox", [0.0, 0.0, @page_height, @page_width])
      |> Map.put("/CropBox", [60.0, 60.0, 762.0, 555.0])
      |> Map.put("/Rotate", 90)

    :ok = Pdf.set_object(qdoc, page_obj, patched)
    {:ok, qdoc}
  end

  # The first (only) leaf page object id under /Pages.
  defp first_page_ref(qdoc) do
    {:ok, catalog} = Pdf.catalog(qdoc)
    {:ref, pages_num, _} = catalog["/Pages"]
    {:ok, pages} = Pdf.get_object(qdoc, pages_num)
    {:ref, kid, _} = List.first(Map.get(pages, "/Kids", []))
    {:ok, kid}
  end

  # Write each field as a widget object, wire them onto the page /Annots and
  # into the /AcroForm /Fields array. Returns the ordered field refs.
  defp write_fields(qdoc, field_specs) do
    font_id = 20

    font = %{
      "/Type" => {:name, "Font"},
      "/Subtype" => {:name, "Type1"},
      "/BaseFont" => {:name, "Helvetica"}
    }

    :ok = Pdf.set_object(qdoc, font_id, font)

    {:ok, page_obj} = first_page_ref(qdoc)

    refs =
      Enum.with_index(field_specs, 30)
      |> Enum.map(fn {spec, id} ->
        {kind, name, rect} = spec

        dict =
          field_dict(kind, name, rect, page_obj)
          |> maybe_add_ap(qdoc, kind)

        :ok = Pdf.set_object(qdoc, {id, 0}, dict)
        {:ref, id, 0}
      end)

    {:ok, page} = Pdf.get_object(qdoc, page_obj)
    annots = Map.get(page, "/Annots", []) |> List.wrap()
    :ok = Pdf.set_object(qdoc, page_obj, Map.put(page, "/Annots", annots ++ refs))

    acroform = %{
      "/Fields" => refs,
      "/NeedAppearances" => true,
      "/DR" => %{"/Font" => %{"/Helv" => {:ref, font_id, 0}}}
    }

    {:ok, acro_id} = Pdf.allocate_object_id(qdoc)
    :ok = Pdf.set_object(qdoc, acro_id, acroform)
    {:ok, catalog} = Pdf.catalog(qdoc)
    :ok = Pdf.set_object(qdoc, 1, Map.put(catalog, "/AcroForm", {:ref, acro_id, 0}))

    refs
  end

  # Checkbox/radio (Btn) fields carry an /AP /N dictionary with /Off and the
  # on-state key so viewers (pdfium, Acrobat, Chrome) can resolve the value.
  defp maybe_add_ap(dict, qdoc, kind) when kind in [:checkbox, :radio] do
    {:ok, off_id} = Pdf.allocate_object_id(qdoc)
    {:ok, on_id} = Pdf.allocate_object_id(qdoc)

    :ok = Pdf.set_object(qdoc, {off_id, 0}, {:stream, %{"/BBox" => [0, 0, 20, 20]}, "q Q"})
    :ok = Pdf.set_object(qdoc, {on_id, 0}, {:stream, %{"/BBox" => [0, 0, 20, 20]}, "q Q"})

    on_key = if kind == :radio, do: "ChoiceA", else: "Yes"
    Map.put(dict, "/AP", %{"/N" => %{"/Off" => {:ref, off_id, 0}, on_key => {:ref, on_id, 0}}})
  end

  defp maybe_add_ap(dict, _qdoc, _kind), do: dict

  defp save(qdoc) do
    {:ok, saved} = Pdf.save(qdoc)
    saved
  end

  defp field_dict(kind, name, rect, page_ref) do
    base = %{
      "/Type" => {:name, "Annot"},
      "/Subtype" => {:name, "Widget"},
      "/T" => name,
      "/Rect" => rect,
      "/P" => page_ref,
      "/F" => 4
    }

    case kind do
      :text ->
        base
        |> Map.merge(%{"/FT" => {:name, "Tx"}, "/DA" => "/Helv 12 Tf 0 g"})

      :checkbox ->
        base
        |> Map.merge(%{
          "/FT" => {:name, "Btn"},
          "/V" => {:name, "Off"},
          "/AS" => {:name, "Off"},
          "/MK" => %{"/CA" => "Yes", "/BC" => [0, 0, 0], "/BG" => [1, 1, 1]}
        })

      :radio ->
        base
        |> Map.merge(%{
          "/FT" => {:name, "Btn"},
          "/Ff" => 32768,
          "/V" => {:name, "ChoiceA"},
          "/AS" => {:name, "Off"},
          "/MK" => %{"/CA" => "5", "/BC" => [0, 0, 0], "/BG" => [1, 1, 1]}
        })

      :combo ->
        base
        |> Map.merge(%{
          "/FT" => {:name, "Ch"},
          "/Ff" => 131_073,
          "/V" => "US",
          "/DA" => "/Helv 12 Tf 0 g",
          "/Opt" => ["US", "CA", "GB"],
          "/I" => [0, 1, 2]
        })

      :list ->
        base
        |> Map.merge(%{
          "/FT" => {:name, "Ch"},
          "/Ff" => 2,
          "/V" => "Apple",
          "/DA" => "/Helv 12 Tf 0 g",
          "/Opt" => ["Apple", "Banana", "Cherry"]
        })

      :button ->
        base
        |> Map.merge(%{
          "/FT" => {:name, "Btn"},
          "/Ff" => 65536,
          "/MK" => %{"/CA" => "Submit"}
        })

      :signature ->
        base
        |> Map.merge(%{"/FT" => {:name, "Sig"}})
    end
  end
end
