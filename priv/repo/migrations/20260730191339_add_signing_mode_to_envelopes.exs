defmodule Quire.Repo.Migrations.AddSigningModeToEnvelopes do
  use Ecto.Migration

  def change do
    alter table(:esign_envelopes) do
      add :signing_mode, :string, default: "sequential"
    end

    execute "UPDATE esign_envelopes SET signing_mode = 'sequential' WHERE signing_mode IS NULL"
  end
end
