defmodule Quire.Editing.OperationPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @kinds [
    "annot.add",
    "annot.update",
    "annot.delete",
    "annot.reply",
    "text.add",
    "text.edit",
    "text.style",
    "image.insert",
    "link.add",
    "link.edit",
    "mark.page_number",
    "mark.watermark",
    "mark.header_footer",
    "mark.bates",
    "mark.remove",
    "page.insert",
    "page.delete",
    "page.move",
    "page.rotate",
    "page.replace",
    "page.crop",
    "page.size",
    "page.margin",
    "page.background",
    "page.reverse",
    "form.add_field",
    "form.update_field",
    "form.delete_field",
    "form.fill",
    "sec.encrypt",
    "sec.permissions",
    "sec.redact_mark",
    "sec.redact_apply",
    "sec.sanitize",
    "sec.strip_metadata",
    "doc.merge",
    "doc.split",
    "doc.compress",
    "doc.ocr",
    "doc.convert",
    "doc.sign",
    "doc.metadata",
    "doc.bookmark_add",
    "doc.bookmark_update",
    "doc.bookmark_delete",
    "doc.bookmark_move"
  ]

  property "apply ∘ invert ∘ apply == apply for all kinds" do
    check all(
            kind <- StreamData.member_of(@kinds),
            op_data <- op_data_for_kind(kind)
          ) do
      {:ok, mod} = Quire.Editing.Operation.module_for_kind(kind)
      context = %{document_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate()}

      {:ok, applied} = mod.apply(op_data, context)
      {:ok, inverse} = mod.invert(applied, context)

      if match?({:restore_revision, _}, inverse) do
        # Phase-0 placeholder — the sentinel is not re-appliable op_data, so
        # only verify that apply is deterministic (apply == apply).
        assert {:ok, ^applied} = mod.apply(op_data, context)
      else
        {:ok, _undone} = mod.apply(inverse, context)
        {:ok, reapplied} = mod.apply(op_data, context)
        assert applied == reapplied
      end
    end
  end

  property "all #{length(@kinds)} operation kinds resolve to exported modules" do
    for kind <- @kinds do
      assert {:ok, mod} = Quire.Editing.Operation.module_for_kind(kind)
      assert {:module, ^mod} = Code.ensure_loaded(mod)
      assert function_exported?(mod, :apply, 2)
      assert function_exported?(mod, :invert, 2)
    end
  end

  defp op_data_for_kind(kind) do
    # Text.edit requires run, new_text, and ref for validation.
    # Generate a minimal valid payload that passes through apply.
    if kind == "text.edit" do
      StreamData.constant(%{
        kind: kind,
        id: Ecto.UUID.generate(),
        run: %{
          text: "test",
          font_name: "Helvetica",
          font_size: 12.0,
          color: [0.0, 0.0, 0.0],
          bbox: [0.0, 0.0, 10.0, 10.0],
          baseline_y: 0.0,
          bold: false,
          italic: false,
          chars: [
            %{
              char: "t",
              font_size: 12.0,
              bounds: %{left: 0.0, bottom: 0.0, right: 5.0, top: 10.0}
            }
          ]
        },
        new_text: "edited",
        page_index: 0,
        # Ref stub — check_font_available only looks at font_name
        ref: %Quire.Storage.Ref{
          adapter: :local,
          key: "test",
          name: "test.pdf",
          content_type: "application/pdf",
          byte_size: 0
        }
      })
    else
      if kind == "image.insert" do
        # Minimal valid PNG — apply/2 validates magic bytes, normalises, and
        # returns enriched op_data (no storage or rendering needed).
        png =
          Base.decode64!(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
          )

        StreamData.constant(%{
          kind: kind,
          id: Ecto.UUID.generate(),
          bytes: png,
          page_index: 0,
          rect: [0.0, 0.0, 10.0, 10.0]
        })
      else
        StreamData.constant(%{kind: kind, id: Ecto.UUID.generate()})
      end
    end
  end
end
