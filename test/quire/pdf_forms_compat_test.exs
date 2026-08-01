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
    "first_name", "agree_checkbox", "option_radio",
    "country_combo", "fruit_list", "submit_btn", "sign_field"
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

      fixture = File.read!("test/fixtures/pdfs/seven_type_form.pdf")
      assert fixture == bytes, "committed fixture is out of date - regenerate it"

      assert {:ok, fields} = FormData.read(bytes)
      types = Enum.map(fields, & &1.type)
      assert :text in types
      assert :checkbox in types
      assert :radio_button in types
      assert :combo_box in types
      assert :list_box in types
      assert :push_button in types
      assert :signature in types
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
      refs = List.wrap(catalog["/AcroForm"]["/Fields"])

      names =
        Enum.map(refs, fn
          {:ref, num, gen} ->
            {:ok, f} = Pdf.get_object(qdoc, {num, gen})
            f["/T"]
          other -> other
        end)

      assert names == @fields_ordered
    end
  end

  describe "fill -> save -> reopen round-trip" do
    test "FormData.write persists /V values across a save/reopen cycle" do
      bytes = SevenFieldForm.build()
      assert {:ok, filled} = FormData.write(bytes, @values)
      assert filled != bytes

      {:ok, reopened} = Pdf.open(filled)
      {:ok, catalog} = Pdf.catalog(reopened)
      refs = List.wrap(catalog["/Acos"]["/Fields"])
      raise "placeholder"
    end
  end
end
OUTER
echo "wrote: $(ls -la "$W/test/quire/pdf_forms_compat_test.exs" 2>&1)"
