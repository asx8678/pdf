defmodule Quire.Repo.Migrations.AddUniqueIndexOnLicensesUserId do
  use Ecto.Migration

  def up do
    # Drop any existing (possibly non-unique) index and recreate as unique
    execute "DROP INDEX IF EXISTS licenses_user_id_index"
    create unique_index(:licenses, [:user_id], name: :licenses_user_id_index)
  end

  def down do
    drop index(:licenses, [:user_id], name: :licenses_user_id_index)
  end
end
