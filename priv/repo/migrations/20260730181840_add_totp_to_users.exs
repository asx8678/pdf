defmodule Quire.Repo.Migrations.AddTotpToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :totp_secret, :binary
      add :totp_enabled, :boolean, default: false, null: false
    end

    create index(:users, [:totp_enabled])
  end
end
