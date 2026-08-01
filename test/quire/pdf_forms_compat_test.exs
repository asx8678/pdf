defmodule Quire.PdfFormsCompatTest do
  # T-126 / pdf-mh2w — Acrobat + Chrome compatibility for authored forms.
  #
  # A form authored here must survive the save / open / fill / submit
  # round-trip in the engine, in the authored tab order, and a signature placed
  # on a rotated, cropped page must survive save/reopen (Gate 7).
  use ExUnit.Case, async: true

  alias Quire.Pdf
  alias Quire.FormData
  alias Quire.Test.SevenFieldForm

  @fields_ordered [
    "first_name",
    "agree_checkbox",
    "option_radio",
    "country_combo",
    "fruit_list",
    "submit_btn",
    "sign_field"
  ]

  @values %{
    "first_name" => "Ada Lovelace",
    "agree_checkbox" => "Yes",
    "option_radio" => "ChoiceA",
    "country_combo" => "CA",
    "fruit_list" => "Cherry"
  }

  describe "authoring the seven-field-type form" do
    test "build() returns a PDF exposing all seven field types" do
      bytes = SevenFieldForm.build()
      assert is_binary(bytes) and byte_size(bytes) > 500
      assert {:ok, _} = Pdf.open(bytes)

      # The committed fixture is the cross-viewer artifact (Acrobat/Chrome).
      # Fresh builds carry PDFium timestamps so they differ byte-for-byte;
      # assert the fixture still opens and exposes the same seven field
      # types instead (regenerate the fixture by hand after structural
      # changes to the authoring code).
      fixture = File.read!("test/fixtures/pdfs/seven_type_form.pdf")
      assert {:ok, fixture_fields} = FormData.read(fixture)
      fixture_types = Enum.map(fixture_fields, & &1.type)

      assert {:ok, fields} = FormData.read(bytes)
      types = Enum.map(fields, & &1.type)
      assert :text in types
      assert :checkbox in types
      assert :radio_button in types
      assert :combo_box in types
      assert :list_box in types
      assert :push_button in types
      assert :signature in types
      assert types == fixture_types, "committed fixture out of date - regenerate it"
    end

    test "pdfium exposes every expected field name" do
      bytes = SevenFieldForm.build()
      assert {:ok, fields} = FormData.read(bytes)
      names = Enum.map(fields, & &1.name)
      assert Enum.sort(names) == Enum.sort(@fields_ordered)
    end

    test "tab order equals the authored AcroForm fields order" do
      bytes = SevenFieldForm.build()
      {:ok, qdoc} = Pdf.open(bytes)
      {:ok, catalog} = Pdf.catalog(qdoc)

      # Navigate to AcroForm object
      {:ref, af_num, af_gen} = catalog["/AcroForm"]
      {:ok, acroform} = Pdf.get_object(qdoc, {af_num, af_gen})
      refs = List.wrap(acroform["/Fields"])

      names =
        Enum.map(refs, fn
          {:ref, num, gen} ->
            {:ok, f} = Pdf.get_object(qdoc, {num, gen})
            f["/T"]

          other ->
            other
        end)

      assert names == @fields_ordered
    end
  end

  describe "fill -> save -> reopen round-trip" do
    test "FormData.write persists /V values across a save/reopen cycle" do
      bytes = SevenFieldForm.build()
      assert {:ok, filled} = FormData.write(bytes, @values)
      assert filled != bytes

      # Reopen and verify values persisted
      {:ok, fields} = FormData.read(filled)
      values_map = Map.new(fields, &{&1.name, &1.value})

      assert values_map["first_name"] == "Ada Lovelace"
      assert values_map["agree_checkbox"] == "Yes"
      assert values_map["option_radio"] == "ChoiceA"
      assert values_map["country_combo"] == "CA"
      assert values_map["fruit_list"] == "Cherry"
    end

    test "FormData.read_values returns flat map of filled values" do
      bytes = SevenFieldForm.build()
      {:ok, filled} = FormData.write(bytes, @values)

      assert {:ok, values} = FormData.read_values(filled)
      assert values["first_name"] == "Ada Lovelace"
      assert values["agree_checkbox"] == "Yes"
      assert values["option_radio"] == "ChoiceA"
      assert values["country_combo"] == "CA"
      assert values["fruit_list"] == "Cherry"
    end

    test "tab order preserved after fill/save cycle" do
      bytes = SevenFieldForm.build()
      {:ok, filled} = FormData.write(bytes, @values)

      {:ok, qdoc} = Pdf.open(filled)
      {:ok, catalog} = Pdf.catalog(qdoc)
      {:ref, af_num, af_gen} = catalog["/AcroForm"]
      {:ok, acroform} = Pdf.get_object(qdoc, {af_num, af_gen})
      refs = List.wrap(acroform["/Fields"])

      names =
        Enum.map(refs, fn {:ref, num, gen} ->
          {:ok, f} = Pdf.get_object(qdoc, {num, gen})
          f["/T"]
        end)

      assert names == @fields_ordered
    end
  end

  describe "Gate 7: signature on rotated/cropped page" do
    test "build_rotated_cropped_sig() creates valid PDF with signature field" do
      {:ok, bytes} = SevenFieldForm.build_rotated_cropped_sig()
      assert is_binary(bytes) and byte_size(bytes) > 500

      {:ok, fields} = FormData.read(bytes)
      types = Enum.map(fields, & &1.type)
      names = Enum.map(fields, & &1.name)

      assert :signature in types
      assert :text in types
      assert "sign_field" in names
      assert "notary_name" in names
    end

    test "signature field survives save/reload cycle" do
      {:ok, bytes} = SevenFieldForm.build_rotated_cropped_sig()

      # Fill the text field
      {:ok, filled} = FormData.write(bytes, %{"notary_name" => "Dr. Turing"})
      assert filled != bytes

      # Reopen and verify signature field still present
      {:ok, fields} = FormData.read(filled)
      types = Enum.map(fields, & &1.type)
      values = Map.new(fields, &{&1.name, &1.value})

      assert :signature in types
      assert values["notary_name"] == "Dr. Turing"
    end

    test "rotated/cropped page preserves CropBox and Rotate" do
      {:ok, bytes} = SevenFieldForm.build_rotated_cropped_sig()
      {:ok, qdoc} = Pdf.open(bytes)

      # Navigate to page object
      {:ok, catalog} = Pdf.catalog(qdoc)
      {:ref, pages_num, _} = catalog["/Pages"]
      {:ok, pages} = Pdf.get_object(qdoc, pages_num)
      {:ref, kid, _} = List.first(Map.get(pages, "/Kids", []))
      {:ok, page} = Pdf.get_object(qdoc, kid)

      # Verify CropBox and Rotate preserved
      assert page["/CropBox"] == [60.0, 60.0, 762.0, 555.0]
      assert page["/Rotate"] == 90
    end

    test "signature widget on rotated page survives save/reload" do
      {:ok, bytes} = SevenFieldForm.build_rotated_cropped_sig()

      # Save to bytes
      {:ok, qdoc} = Pdf.open(bytes)
      {:ok, saved} = Pdf.save(qdoc)
      assert saved != bytes

      # Reopen and verify signature field intact
      {:ok, fields} = FormData.read(saved)
      names = Enum.map(fields, & &1.name)
      assert "sign_field" in names
    end
  end
end
