defmodule Quire.Pdf.AcroFormTest do
  @moduledoc """
  Tests for `Quire.Pdf.AcroForm.rebuild_fields/1` — rediscovering widget
  annotations after a page import that dropped /AcroForm.
  """

  use ExUnit.Case, async: true

  alias Quire.Pdf

  describe "rebuild_fields/1" do
    defp form_with_two_widgets do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, {595.0, 842.0})
      {:ok, doc} = ExPdfium.add_page(doc, {595.0, 842.0})
      {:ok, bytes} = ExPdfium.save_to_bytes(doc)

      {:ok, qdoc} = Pdf.open(bytes)

      # Widget on page 0 (object 4) — in /AcroForm
      widget0 = %{
        "/Type" => {:name, "Annot"},
        "/Subtype" => {:name, "Widget"},
        "/FT" => {:name, "Tx"},
        "/T" => "Name",
        "/V" => "Alice",
        "/DA" => "/Helv 12 Tf 0 g",
        "/Rect" => [50, 700, 400, 740],
        "/P" => {:ref, 4, 0},
        "/F" => 4
      }

      # Widget on page 1 (object 5) — NOT in /AcroForm
      widget1 = %{
        "/Type" => {:name, "Annot"},
        "/Subtype" => {:name, "Widget"},
        "/FT" => {:name, "Tx"},
        "/T" => "Email",
        "/V" => "alice@example.com",
        "/DA" => "/Helv 12 Tf 0 g",
        "/Rect" => [50, 600, 400, 640],
        "/P" => {:ref, 5, 0},
        "/F" => 4
      }

      :ok = Pdf.set_object(qdoc, 50, widget0)
      :ok = Pdf.set_object(qdoc, 51, widget1)

      # Page 0 /Annots includes widget0
      {:ok, page0} = Pdf.get_object(qdoc, 4)
      :ok = Pdf.set_object(qdoc, 4, Map.put(page0, "/Annots", [{:ref, 50, 0}]))

      # Page 1 /Annots includes widget1
      {:ok, page1} = Pdf.get_object(qdoc, 5)
      :ok = Pdf.set_object(qdoc, 5, Map.put(page1, "/Annots", [{:ref, 51, 0}]))

      # Existing /AcroForm only links widget0
      :ok =
        Pdf.set_object(qdoc, 52, %{
          "/Fields" => [{:ref, 50, 0}],
          "/DR" => %{"/Font" => %{"/Helv" => {:ref, 20, 0}}},
          "/NeedAppearances" => true
        })

      {:ok, catalog} = Pdf.catalog(qdoc)
      :ok = Pdf.set_object(qdoc, 1, Map.put(catalog, "/AcroForm", {:ref, 52, 0}))

      qdoc
    end

    test "adds page-1 widget to /Fields" do
      qdoc = form_with_two_widgets()

      # Before rebuild, /AcroForm has only widget0
      {:ok, cat_before} = Pdf.catalog(qdoc)
      {:ok, af_before} = Pdf.get_object(qdoc, cat_before["/AcroForm"])
      assert Map.get(af_before, "/Fields") == [{:ref, 50, 0}]

      # Rebuild
      assert :ok = Pdf.AcroForm.rebuild_fields(qdoc)

      # After rebuild, /AcroForm has both widgets
      {:ok, cat_after} = Pdf.catalog(qdoc)
      af_ref = cat_after["/AcroForm"]
      assert match?({:ref, _, _}, af_ref)

      {:ok, af_after} = Pdf.get_object(qdoc, af_ref)
      fields = Map.get(af_after, "/Fields", [])
      assert length(fields) == 2
      assert {:ref, 50, 0} in fields
      assert {:ref, 51, 0} in fields

      # Existing properties preserved
      assert Map.get(af_after, "/NeedAppearances") == true
      assert match?(%{"/Font" => _}, Map.get(af_after, "/DR"))
    end

    test "no-op when no widget annotations exist" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, {595.0, 842.0})
      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, qdoc} = Pdf.open(bytes)

      {:ok, cat_before} = Pdf.catalog(qdoc)
      refute Map.has_key?(cat_before, "/AcroForm")

      assert :ok = Pdf.AcroForm.rebuild_fields(qdoc)

      {:ok, cat_after} = Pdf.catalog(qdoc)

      refute Map.has_key?(cat_after, "/AcroForm"),
             "Should not create /AcroForm when no widgets exist"
    end

    test "survives save and reopen" do
      qdoc = form_with_two_widgets()
      assert :ok = Pdf.AcroForm.rebuild_fields(qdoc)

      {:ok, saved} = Pdf.save(qdoc)
      {:ok, reopened} = Pdf.open(saved)

      {:ok, catalog} = Pdf.catalog(reopened)
      assert match?({:ref, _, _}, catalog["/AcroForm"])

      {:ok, af} = Pdf.get_object(reopened, catalog["/AcroForm"])
      assert length(Map.get(af, "/Fields", [])) == 2
    end
  end
end
