defmodule Quire.Repo.Migrations.CreateAnnotationReplies do
  use Ecto.Migration

  def up do
    create table(:annotation_replies, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :annotation_id,
          references(:annotations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :author_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :content, :text, null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:annotation_replies, [:annotation_id])
    create index(:annotation_replies, [:author_id])
  end

  def down do
    drop_if_exists table(:annotation_replies)
  end
end
