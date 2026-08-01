defmodule Quire.Repo.Migrations.CreateDigitalSignatures do
  use Ecto.Migration

  # per plan3.md §5.4 (lines 944-952). uuidv7() is native PG18.
  def change do
    create table(:digital_signatures, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :revision_id, references(:document_revisions, type: :binary_id), null: false

      add :signer_name, :string
      add :signer_email, :string
      add :certificate_subject, :string
      add :certificate_issuer, :string
      add :serial, :string
      add :signed_at, :utc_datetime
      add :tsa_url, :string
      add :pades_level, :string, null: false
      add :field_name, :string
      add :validation_status, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:digital_signatures, [:document_id])
    create index(:digital_signatures, [:revision_id])
  end
end
