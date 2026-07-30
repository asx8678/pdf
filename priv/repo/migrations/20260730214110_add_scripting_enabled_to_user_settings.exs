defmodule Quire.Repo.Migrations.AddScriptingEnabledToUserSettings do
  use Ecto.Migration

  def up do
    alter table(:user_settings) do
      add :scripting_enabled, :boolean, default: false
    end
  end

  def down do
    alter table(:user_settings) do
      remove :scripting_enabled
    end
  end
end
