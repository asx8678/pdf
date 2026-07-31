defmodule Quire.Repo.Migrations.AddSignaturesToUserSettings do
  use Ecto.Migration

  def up do
    execute """
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'user_settings' AND column_name = 'signatures'
      ) THEN
        ALTER TABLE user_settings ADD COLUMN signatures jsonb DEFAULT '[]'::jsonb;
      END IF;
    END $$;
    """
  end

  def down do
    execute "ALTER TABLE user_settings DROP COLUMN IF EXISTS signatures"
  end
end
