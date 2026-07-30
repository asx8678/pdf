defmodule Quire.Repo.Migrations.AddHighlightFieldsToUserSettings do
  use Ecto.Migration

  def change do
    alter table(:user_settings) do
      add :highlight_fields, :boolean, default: false, null: false
    end
  end
end
