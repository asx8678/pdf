defmodule Quire.Repo.Migrations.CreateSigningCredentialsTable do
  use Ecto.Migration

  # The ban on CREATE_EXTENSION in migrations (plan3.md §3.4) is respected here.
  # uuidv7() is native PG18 — no extension needed.

  def up do
    create table(:signing_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :label, :string, null: false
      add :subject, :string
      add :issuer, :string
      add :serial, :string
      add :not_after, :utc_datetime
      add :keystore_ref_key, :string, null: false
      add :passphrase_encrypted, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:signing_credentials, [:user_id])
    create unique_index(:signing_credentials, [:user_id, :label])
  end

  def down do
    drop_if_exists table(:signing_credentials)
  end
end
