defmodule Quire.Repo.Migrations.AddAttachmentRefToAnnotations do
  use Ecto.Migration

  def up do
    alter table(:annotations) do
      # FileAttachment annotations reference a stored blob via Storage.Ref
      add :attachment_ref, :map
    end

    # The stamps field is stored in user_settings (added via :map in schema only,
    # no column change needed since user_settings already uses a JSON column
    # for signatures and qat_items — the new stamps field goes in the same
    # jsonb/text column on the table).

    # Existing annotations table already has all needed columns:
    # id, revision_id, page_index, kind, rect, quad_points, path_data,
    # color, opacity, border_width, content, author, inserted_at, updated_at
  end

  def down do
    alter table(:annotations) do
      remove :attachment_ref
    end
  end
end
