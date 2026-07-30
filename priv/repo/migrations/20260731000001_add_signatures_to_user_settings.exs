defmodule Quire.Repo.Migrations.AddSignaturesToUserSettings do
  use Ecto.Migration

  def up do
    alter table(:user_settings) do
      add :signatures, :map, default: fragment("'[]'::jsonb")
    end
  end

  def down do
    alter table(:user_settings) do
      remove :signatures
    end
  end
end
