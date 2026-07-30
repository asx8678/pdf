defmodule Quire.Repo.Migrations.AddHasTextToDocumentPages do
  use Ecto.Migration

  def up do
    alter table(:document_pages) do
      add :has_text, :boolean, default: false, null: false
    end
  end

  def down do
    alter table(:document_pages) do
      remove :has_text
    end
  end
end
