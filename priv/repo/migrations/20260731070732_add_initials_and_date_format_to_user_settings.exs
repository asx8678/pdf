defmodule Quire.Repo.Migrations.AddInitialsAndDateFormatToUserSettings do
  use Ecto.Migration

  def up do
    execute """
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'user_settings' AND column_name = 'initials'
      ) THEN
        ALTER TABLE user_settings ADD COLUMN initials jsonb DEFAULT '{}'::jsonb;
      END IF;
    END $$;
    """

    execute """
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'user_settings' AND column_name = 'signing_date_format'
      ) THEN
        ALTER TABLE user_settings ADD COLUMN signing_date_format varchar DEFAULT '%Y-%m-%d';
      END IF;
    END $$;
    """

    execute """
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'user_settings' AND column_name = 'signer_name'
      ) THEN
        ALTER TABLE user_settings ADD COLUMN signer_name varchar DEFAULT NULL;
      END IF;
    END $$;
    """

    # The signatures/stamps/qat_items columns were created with a `'[]'::jsonb`
    # DB default, which Ecto's `:map` type cannot load (jsonb arrays). Rows
    # inserted without those fields (e.g. first settings save) therefore
    # crashed on load. Normalise any existing arrays to objects and fix the
    # defaults for future inserts (incl. insert_all paths).
    execute """
    UPDATE user_settings
    SET signatures = '{}'::jsonb
    WHERE signatures IS NOT NULL AND jsonb_typeof(signatures) = 'array';
    """

    execute """
    ALTER TABLE user_settings ALTER COLUMN signatures SET DEFAULT '{}'::jsonb;
    """

    execute """
    UPDATE user_settings
    SET stamps = '{}'::jsonb
    WHERE stamps IS NOT NULL AND jsonb_typeof(stamps) = 'array';
    """

    execute """
    ALTER TABLE user_settings ALTER COLUMN stamps SET DEFAULT '{}'::jsonb;
    """

    execute """
    UPDATE user_settings
    SET qat_items = '{}'::jsonb
    WHERE qat_items IS NOT NULL AND jsonb_typeof(qat_items) = 'array';
    """

    execute """
    ALTER TABLE user_settings ALTER COLUMN qat_items SET DEFAULT '{}'::jsonb;
    """

    execute """
    UPDATE user_settings
    SET initials = '{}'::jsonb
    WHERE initials IS NOT NULL AND jsonb_typeof(initials) = 'array';
    """
  end

  def down do
    execute "ALTER TABLE user_settings DROP COLUMN IF EXISTS signer_name"
    execute "ALTER TABLE user_settings DROP COLUMN IF EXISTS signing_date_format"
    execute "ALTER TABLE user_settings DROP COLUMN IF EXISTS initials"
  end
end
