defmodule Quire.Repo.Migrations.CreateUserSettings do
  use Ecto.Migration

  # The ban on CREATE_EXTENSION in migrations (plan3.md §3.4) is respected here.
  # uuidv7() is native PG18 — no extension needed.

  def up do
    create table(:user_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :theme, :string, default: "system"
      add :default_zoom, :float, default: 1.0
      add :default_view_mode, :string, default: "single"
      add :ruler_visible, :boolean, default: true
      add :grid_visible, :boolean, default: false

      add :qat_items, :map

      add :recent_limit, :integer, default: 20
      add :ocr_default_lang, :string, default: "eng"
      add :measurement_unit, :string, default: "mm"
      add :autosave_enabled, :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_settings, [:user_id])
  end

  def down do
    drop_if_exists table(:user_settings)
  end
end
