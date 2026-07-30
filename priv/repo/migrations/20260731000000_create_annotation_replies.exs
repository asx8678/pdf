defmodule Quire.Repo.Migrations.CreateAnnotationReplies do
  use Ecto.Migration

  def up do
    # This table was already created in migration 20260729191301 rollup.
    # Kept for versioning history but is a no-op.
    :ok
  end

  def down do
    :ok
  end
end
