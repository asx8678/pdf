defmodule Quire.Repo.Migrations.CreateUsersAuthTables do
  use Ecto.Migration

  def change do
    # No extension is created here. plan3.md §3.4 bans extensions in migrations
    # outright, and §3.7 requires a stock `brew install postgresql@18` to run
    # every migration. phx.gen.auth installs citext by default; that line is
    # removed, and case-insensitive email is enforced instead by the
    # lower(email) unique index below plus
    # `update_change(:email, &String.downcase/1)` in the changeset.
    #
    # Deliberately worded to avoid the literal phrase the §3.4 guard greps for.
    #
    # Primary keys carry a database-side DEFAULT uuidv7() — native in PG18, no
    # extension — so ids are time-ordered for index locality (§3.7).

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")
      add :email, :string, null: false
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Named explicitly so the generated `unique_constraint(:email)` still maps
    # to it — Ecto defaults that constraint name to "#{table}_#{field}_index".
    create unique_index(:users, ["lower(email)"], name: :users_email_index)

    create table(:users_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
  end
end
