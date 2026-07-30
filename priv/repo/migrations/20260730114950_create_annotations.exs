defmodule Quire.Repo.Migrations.CreateAnnotations do
  use Ecto.Migration

  def up do
    create table(:annotations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :revision_id,
          references(:document_revisions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :page_index, :integer, null: false
      add :kind, :string, null: false
      add :quad_points, :map
      add :color, :map
      add :opacity, :float
      add :content, :text

      timestamps(type: :utc_datetime)
    end

    create index(:annotations, [:revision_id])
    create index(:annotations, [:revision_id, :page_index])
  end

  def down do
    drop_if_exists table(:annotations)
  end
end
