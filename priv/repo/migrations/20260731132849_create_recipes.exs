defmodule Quire.Repo.Migrations.CreateRecipes do
  use Ecto.Migration

  def change do
    create table(:recipes, primary_key: false) do
      add :id, :binary_id, primary_key: true, autogenerate: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :steps, :map, null: false, default: %{}

      timestamps()
    end

    create index(:recipes, [:user_id])
    create unique_index(:recipes, [:user_id, :name])
  end
end
