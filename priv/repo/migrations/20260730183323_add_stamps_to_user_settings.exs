defmodule Quire.Repo.Migrations.AddStampsToUserSettings do
  use Ecto.Migration

  def change do
    alter table(:user_settings) do
      add :stamps, :map
    end
  end
end
