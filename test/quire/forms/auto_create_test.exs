defmodule Quire.Forms.AutoCreateTest do
  use Quire.DataCase, async: false

  alias Quire.Forms.{Detect, AutoCreate}
  alias Quire.Documents.{Document, Revision}
  alias Quire.Repo

  @fixture_dir Path.expand("../../fixtures/pdfs", __DIR__)
  @scanned Path.join(@fixture_dir, "scanned_300dpi.pdf")

  setup do
    user =
      %Quire.Accounts.User{
        id: Ecto.UUID.generate(),
        email: "user-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "x"
      }
      |> Repo.insert!()

    %{user: user}
  end

  defp store_fixture do
    {:ok, ref} = Quire.Storage.put(File.read!(@scanned), name: "scanned_300dpi.pdf")
    ref
  end

  defp document_with_revision(user) do
    doc =
      %Document{id: Ecto.UUID.generate(), user_id: user.id, title: "scanned.pdf", page_count: 1}
      |> Repo.insert!()

    ref = store_fixture()

    source_map = %{
      "storage_ref" => %{
        "adapter" => to_string(ref.adapter),
        "key" => ref.key,
        "name" => ref.name,
        "content_type" => ref.content_type,
        "byte_size" => ref.byte_size
      },
      "filename" => "scanned.pdf"
    }

    rev =
      %Revision{
        id: Ecto.UUID.generate(),
        document_id: doc.id,
        label: "Original upload",
        source: source_map
      }
      |> Repo.insert!()

    doc =
      doc
      |> Ecto.Changeset.change(%{current_revision_id: rev.id})
      |> Repo.update!()

    %{doc: doc, rev: rev, ref: ref}
  end

  describe "detect_ref/2 (T-125 done-when)" do
    test "finds the 5 synthetic fields on the scanned fixture" do
      ref = store_fixture()

      assert {:ok, %{total: 5, fields: fields}} = Detect.detect_ref(ref, dpi: 150)

      assert Enum.count(fields, &(&1.kind == :text)) == 4
      assert Enum.count(fields, &(&1.kind == :checkbox)) == 1

      # Ground truth (pdf points, y-up): two 178×20 / 328×20 boxes, one
      # 20×20 checkbox, two underline blanks at y 560 and y 520.
      assert Enum.all?(fields, &(&1.page_index == 0))

      text_rects = for f <- fields, f.kind == :text, do: f.rect
      assert Enum.any?(text_rects, &rect_near?(&1, [72, 700, 250, 720]))
      assert Enum.any?(text_rects, &rect_near?(&1, [72, 660, 400, 680]))
      assert Enum.any?(text_rects, &rect_near?(&1, [72, 560, 300, 575]))
      assert Enum.any?(text_rects, &rect_near?(&1, [72, 520, 350, 535]))

      [checkbox] = for f <- fields, f.kind == :checkbox, do: f.rect
      assert rect_near?(checkbox, [72, 610, 92, 630])
    end
  end

  describe "commit/2" do
    test "turns detections into real AcroForm fields readable by PDFium" do
      ref = store_fixture()
      {:ok, %{total: 5, fields: fields}} = Detect.detect_ref(ref, dpi: 150)

      source_bytes = File.read!(@scanned)
      assert {:ok, new_bytes} = AutoCreate.commit(source_bytes, fields)
      refute new_bytes == source_bytes

      {:ok, doc} = ExPdfium.open_blob(new_bytes)
      {:ok, form_fields} = ExPdfium.form_fields(doc)

      assert length(form_fields) == 5

      names = Enum.map(form_fields, & &1.name)
      assert Enum.sort(names) == ["checkbox5", "text1", "text2", "text3", "text4"]

      assert Enum.all?(form_fields, &(&1.page == 0))
      assert Enum.count(form_fields, &(&1.type == :text)) == 4
      assert Enum.count(form_fields, &(&1.type == :checkbox)) == 1
    end

    test "commits an empty detection list without adding fields" do
      source_bytes = File.read!(@scanned)
      assert {:ok, new_bytes} = AutoCreate.commit(source_bytes, [])

      {:ok, pdf_doc} = ExPdfium.open_blob(new_bytes)
      {:ok, form_fields} = ExPdfium.form_fields(pdf_doc)
      assert form_fields == []
    end
  end

  describe "commit_revision/2" do
    test "persists a new revision and switches the document pointer", %{user: user} do
      %{doc: doc, rev: old_rev, ref: ref} = document_with_revision(user)
      {:ok, %{total: 5, fields: fields}} = Detect.detect_ref(ref, dpi: 150)

      assert {:ok, %{revision: new_rev, bytes: bytes}} = AutoCreate.commit_revision(doc, fields)
      assert new_rev.id != old_rev.id
      assert new_rev.document_id == doc.id
      assert new_rev.label =~ "Auto-create fields"
      assert is_binary(bytes)

      # Document now points at the new revision, whose storage holds a PDF
      # with the 5 fields.
      reloaded = Repo.get!(Document, doc.id)
      assert reloaded.current_revision_id == new_rev.id

      {:ok, stored_bytes} = Quire.Storage.get(Quire.Documents.Revision.storage_ref(new_rev))
      assert stored_bytes == bytes

      {:ok, pdf_doc} = ExPdfium.open_blob(stored_bytes)
      {:ok, form_fields} = ExPdfium.form_fields(pdf_doc)
      assert length(form_fields) == 5
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp rect_near?([x0, y0, x1, y1], [ex0, ey0, ex1, ey1]) do
    abs(x0 - ex0) <= 1.0 and abs(y0 - ey0) <= 1.0 and abs(x1 - ex1) <= 1.0 and abs(y1 - ey1) <= 1.0
  end
end
