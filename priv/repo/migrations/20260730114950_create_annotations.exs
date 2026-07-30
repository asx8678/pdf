defmodule Quire.Repo.Migrations.CreateAnnotations do
  use Ecto.Migration

  def up do
    # The annotations table was already created in migration 20260729191301
    # (CreateEditingFormsSecurityJobsCloudTables) with a superset of columns.
    # This migration is kept for versioning history but is a no-op.
    :ok
  end

  def down do
    :ok
  end
end
