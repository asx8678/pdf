defmodule Quire.Editing.OperationPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @kinds [
    "annot.add", "annot.update", "annot.delete", "annot.reply",
    "text.add", "text.edit", "text.style", "image.insert", "link.add", "link.edit",
    "mark.page_number", "mark.watermark", "mark.header_footer", "mark.bates", "mark.remove",
    "page.insert", "page.delete", "page.move", "page.rotate", "page.replace",
    "page.crop", "page.size", "page.margin", "page.background", "page.reverse",
    "form.add_field", "form.update_field", "form.delete_field", "form.fill",
    "sec.encrypt", "sec.permissions", "sec.redact_mark", "sec.redact_apply",
    "sec.sanitize", "sec.strip_metadata",
    "doc.merge", "doc.split", "doc.compress", "doc.ocr", "doc.convert", "doc.sign",
    "doc.metadata", "doc.bookmark_add", "doc.bookmark_update", "doc.bookmark_delete", "doc.bookmark_move"
  ]

  property "apply ∘ invert ∘ apply == apply for all kinds" do
    check all kind <- StreamData.member_of(@kinds),
              op_data <- op_data_for_kind(kind) do
      {:ok, mod} = Quire.Editing.Operation.module_for_kind(kind)
      context = %{document_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate()}

      {:ok, applied} = mod.apply(op_data, context)
      {:ok, inverse} = mod.invert(applied, context)
      {:ok, _undone} = mod.apply(inverse, context)
      {:ok, reapplied} = mod.apply(op_data, context)

      assert applied == reapplied
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
    StreamData.constant(%{kind: kind, id: Ecto.UUID.generate()})
  end
end
