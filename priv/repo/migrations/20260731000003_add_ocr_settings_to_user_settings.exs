defmodule Quire.Repo.Migrations.AddOcrSettingsToUserSettings do
  use Ecto.Migration

  def up do
    alter table(:user_settings) do
      add :ocr_auto_deskew, :boolean, default: true
      add :ocr_auto_rotate, :boolean, default: true
      add :ocr_clean, :boolean, default: true
      add :ocr_optimise_level, :integer, default: 1
    end
  end

  def down do
    alter table(:user_settings) do
      remove :ocr_auto_deskew
      remove :ocr_auto_rotate
      remove :ocr_clean
      remove :ocr_optimise_level
    end
  end
end
