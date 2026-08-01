defmodule Quire.Forms.AutoDetectTest do
  use Quire.DataCase, async: false

  alias Quire.Forms.{Detect, AutoCreate}

  @fixture_dir Path.expand("../../fixtures/pdfs", __DIR__)
  @scanned Path.join(@fixture_dir, "scanned_300dpi.pdf")
  @acros Path.join(@fixture_dir, "acroform.pdf")

  # Fill & Sign auto-detect (§9.4, T-116). Coverage of the detection half:
  # AcroForm fields read via PDFium `form_fields`, plus the heuristic
  # line/box fallback for scanned forms, and the shape each returns so the
  # client can place a text box over every detected field.
  describe "form_fields/1 (T-116 §9.4)" do
    test "reads a committed AcroForm into the per-page detection shape" do
      # Build a PDF with real AcroForm fields (T-125 commit), then read them
      # back through the PDFium layer the same way `autodetect/2` does.
      ref = store(@scanned)
      {:ok, %{fields: detections}} = Detect.detect_ref(ref, dpi: 150)
      {:ok, new_bytes} = AutoCreate.commit(File.read!(@scanned), detections)
      acro_ref = store(new_bytes)

      assert {:ok, fields} = Detect.form_fields(acro_ref)
      assert length(fields) == 5

      # Normalised: one flat rect per field, keyed by page, with a name.
      assert Enum.all?(fields, &(&1.page_index == 0))
      assert Enum.any?(fields, &(&1.name == "text1"))
      assert Enum.any?(fields, &(&1.name == "checkbox5"))

      for f <- fields do
        assert match?([x0, y0, x1, y1] when x0 < x1 and y0 < y1, f.rect)
      end
    end

    test "returns an empty list when the document has no AcroForm" do
      ref = store(@scanned)
      assert {:ok, []} = Detect.form_fields(ref)
    end
  end

  describe "autodetect/2 (T-116 §9.4)" do
    test "falls back to the heuristic detector for a scanned form" do
      ref = store(@scanned)

      assert {:ok, %{source: :scanned, total: 5, fields: fields}} =
               Detect.autodetect(ref, dpi: 150)

      assert Enum.count(fields, &(&1.kind == :text)) == 4
      assert Enum.count(fields, &(&1.kind == :checkbox)) == 1
    end

    test "prefers the AcroForm when one exists" do
      ref = store(@scanned)
      {:ok, %{fields: fields}} = detect_form(ref)
      {:ok, new_bytes} = AutoCreate.commit(File.read!(@scanned), fields)
      acro_ref = store(new_bytes)

      assert {:ok, %{source: :acroform, total: 5, fields: acro_fields}} =
               Detect.autodetect(acro_ref, dpi: 150)

      # The committed AcroForm path reports names; the rects are in PDF
      # user-space points and well-formed.
      assert Enum.any?(acro_fields, &(&1.name == "text1"))
    end

    test "detects fields on the acroform.pdf fixture (§9.4 done-when)" do
      ref = store(@acros)

      # autodetect/2 prefers the real AcroForm (PDFium form_fields) when one
      # exists — the done-when for §9.4 — so the fixture's five fields must
      # surface with names and on page 0.
      assert {:ok, %{source: :acroform, total: total, fields: fields}} =
               Detect.autodetect(ref, dpi: 150)

      assert total == 5
      assert Enum.all?(fields, &(&1.page_index == 0))
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp store(path_or_bytes) do
    bytes =
      if is_binary(path_or_bytes) and String.ends_with?(path_or_bytes, ".pdf"),
        do: File.read!(path_or_bytes),
        else: path_or_bytes

    {:ok, ref} = Quire.Storage.put(bytes, name: "autodetect.pdf")
    ref
  end

  defp detect_form(ref) do
    Detect.detect_ref(ref, dpi: 150)
  end
end
