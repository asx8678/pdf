defmodule Quire.Repo.Migrations.AddThresholdToOcrResults do
  @moduledoc """
  Adds `threshold` and `options` columns to `ocr_results` for the
  confidence-report feature (§T-142).
  """

  use Ecto.Migration

  def up do
    alter table(:ocr_results) do
      add :threshold, :float, default: 80.0
      add :options, :map, default: %{}
    end
  end

  def down do
    alter table(:ocr_results) do
      remove :threshold
      remove :options
    end
  end
end
