defmodule Quire.Repo.Migrations.AddLastRemindedAtToEnvelopes do
  use Ecto.Migration

  def change do
    alter table(:esign_envelopes) do
      add :last_reminded_at, :utc_datetime
    end
  end
end
