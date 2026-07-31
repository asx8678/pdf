defmodule Quire.Repo.Migrations.AddOcrSettingsToUserSettings do
  use Ecto.Migration

  def up do
    execute """
    DO $$ BEGIN
      IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'user_settings' AND column_name = 'ocr_auto_deskew') THEN
        ALTER TABLE user_settings ADD COLUMN ocr_auto_deskew boolean DEFAULT true;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'user_settings' AND column_name = 'ocr_auto_rotate') THEN
        ALTER TABLE user_settings ADD COLUMN ocr_auto_rotate boolean DEFAULT true;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'user_settings' AND column_name = 'ocr_clean') THEN
        ALTER TABLE user_settings ADD COLUMN ocr_clean boolean DEFAULT true;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'user_settings' AND column_name = 'ocr_optimise_level') THEN
        ALTER TABLE user_settings ADD COLUMN ocr_optimise_level integer DEFAULT 1;
      END IF;
    END $$;
    """
  end

  def down do
    execute """
    ALTER TABLE user_settings
      DROP COLUMN IF EXISTS ocr_auto_deskew,
      DROP COLUMN IF EXISTS ocr_auto_rotate,
      DROP COLUMN IF EXISTS ocr_clean,
      DROP COLUMN IF EXISTS ocr_optimise_level;
    """
  end
end
