defmodule Quire.Repo.Migrations.AddMissingUserSettingsSchemaColumns do
  use Ecto.Migration

  def change do
    alter table(:user_settings) do
      add :whiteout_warning_dismissed, :boolean, default: false
    end
  end
end
