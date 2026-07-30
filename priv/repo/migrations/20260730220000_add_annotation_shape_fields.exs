defmodule Quire.Repo.Migrations.AddAnnotationShapeFields do
  use Ecto.Migration

  def up do
    # These columns already exist from the rollup migration 20260729191301.
    # This migration is kept for versioning history but is a no-op.
    :ok
  end

  def down do
    :ok
  end
end
