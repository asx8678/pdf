defmodule Quire.Repo.Migrations.AddThresholdToOcrResults do
  @moduledoc """
  Adds `threshold` and `options` columns to `ocr_results` for the
  confidence-report feature (§T-142).
  """

  use Ecto.Migration

  def up do
    execute """
    DO $$ BEGIN
      IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'ocr_results' AND column_name = 'threshold') THEN
        ALTER TABLE ocr_results ADD COLUMN threshold float DEFAULT 80.0;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'ocr_results' AND column_name = 'options') THEN
        ALTER TABLE ocr_results ADD COLUMN options jsonb DEFAULT '{}'::jsonb;
      END IF;
    END $$;
    """
  end

  def down do
    execute """
    ALTER TABLE ocr_results
      DROP COLUMN IF EXISTS threshold,
      DROP COLUMN IF EXISTS options;
    """
  end
end
