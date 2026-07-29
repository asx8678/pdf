defmodule Quire.Repo.Migrations.CreateEditingFormsSecurityJobsCloudTables do
  use Ecto.Migration

  # The ban on CREATE_EXTENSION in migrations (plan3.md §3.4) is respected
  # here: no build-time extension is loaded because §3.7 requires a stock
  # `brew install postgresql@18` to run every migration. uuidv7() is native
  # in PG18, a core function, not an extension.
  #
  # Every primary key column uses DEFAULT uuidv7() so that hand-written SQL
  # and external tools still get time-ordered UUIDs even when the Elixir side
  # omits the id from INSERT.

  def up do
    # ── §5.3 Editing ──────────────────────────────────────────────────────

    create table(:edit_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :revision_id, references(:document_revisions, type: :binary_id, on_delete: :nilify_all)
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :kind, :string, null: false
      add :payload, :map, null: false
      add :inverse, :map, null: false
      add :applied_side, :string, null: false, default: "client"
      add :undone, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:edit_operations, [:document_id, :seq], unique: true)
    create index(:edit_operations, [:revision_id])
    create index(:edit_operations, [:user_id])

    create table(:annotations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :page_index, :integer, null: false
      add :kind, :string, null: false
      add :rect, :map, null: false
      add :quad_points, :map
      add :path_data, :map
      add :contents, :text
      add :author, :string
      add :color, :string
      add :opacity, :float
      add :border_width, :float
      add :flags, :map
      add :pdf_object_ref, :map
      add :replies_count, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:annotations, [:document_id])

    create table(:annotation_replies, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :annotation_id,
          references(:annotations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:annotation_replies, [:annotation_id])
    create index(:annotation_replies, [:user_id])

    create table(:text_edits, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :page_index, :integer, null: false
      add :kind, :string, null: false
      add :rect, :map
      add :style, :map
      add :content, :map

      add :applied_revision_id,
          references(:document_revisions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:text_edits, [:document_id])
    create index(:text_edits, [:applied_revision_id])

    # ── §5.4 Forms, security, signing ─────────────────────────────────────

    create table(:form_fields, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :page_index, :integer
      add :name, :string
      add :kind, :string, null: false
      add :rect, :map
      add :required, :boolean, default: false
      add :read_only, :boolean, default: false
      add :default_value, :string
      add :options, :map
      add :validation, :map
      add :tab_order, :integer
      add :appearance, :map
    end

    create index(:form_fields, [:document_id])

    create table(:form_submissions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :values, :map, null: false
      add :submitted_at, :utc_datetime, null: false
    end

    create index(:form_submissions, [:document_id])
    create index(:form_submissions, [:user_id])

    create table(:security_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_password_set, :boolean, default: false
      add :owner_password_set, :boolean, default: false
      add :key_length, :integer, default: 256
      add :permissions, :map

      add :applied_revision_id,
          references(:document_revisions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:security_policies, [:document_id])

    create table(:redactions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :page_index, :integer, null: false
      add :rect, :map, null: false
      add :reason_code, :string
      add :overlay_text, :string
      add :applied, :boolean, default: false

      add :applied_revision_id,
          references(:document_revisions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:redactions, [:document_id])

    create table(:digital_signatures, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :revision_id, references(:document_revisions, type: :binary_id, on_delete: :nilify_all)
      add :signer_name, :string
      add :signer_email, :string
      add :certificate_subject, :string
      add :certificate_issuer, :string
      add :serial, :string
      add :signed_at, :utc_datetime
      add :tsa_url, :string
      add :pades_level, :string
      add :field_name, :string
      add :validation_status, :map

      timestamps(type: :utc_datetime)
    end

    create index(:digital_signatures, [:document_id])
    create index(:digital_signatures, [:revision_id])

    create table(:esign_envelopes, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :owner_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :subject, :string
      add :message, :text
      add :status, :string, null: false, default: "draft"
      add :expires_at, :utc_datetime
      add :sent_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:esign_envelopes, [:document_id])
    create index(:esign_envelopes, [:owner_id])

    create table(:esign_signers, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :envelope_id,
          references(:esign_envelopes, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :email, :string, null: false
      add :order, :integer
      add :role, :string
      add :status, :string, null: false, default: "pending"
      add :access_token, :string
      add :signed_at, :utc_datetime
      add :ip_address, :string
      add :user_agent, :string
    end

    create index(:esign_signers, [:envelope_id])

    create table(:esign_fields, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :envelope_id,
          references(:esign_envelopes, type: :binary_id, on_delete: :delete_all),
          null: false

      add :signer_id,
          references(:esign_signers, type: :binary_id, on_delete: :delete_all),
          null: false

      add :page_index, :integer, null: false
      add :rect, :map, null: false
      add :kind, :string, null: false
      add :required, :boolean, default: false
      add :value, :string
    end

    create index(:esign_fields, [:envelope_id])
    create index(:esign_fields, [:signer_id])

    create table(:esign_audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :envelope_id,
          references(:esign_envelopes, type: :binary_id, on_delete: :delete_all),
          null: false

      add :signer_id,
          references(:esign_signers, type: :binary_id, on_delete: :nilify_all)

      add :event, :string, null: false
      add :metadata, :map
      add :occurred_at, :utc_datetime, null: false
    end

    create index(:esign_audit_events, [:envelope_id])
    create index(:esign_audit_events, [:signer_id])

    # ── §5.5 Jobs, OCR, translation ───────────────────────────────────────

    create table(:operations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :progress, :integer, default: 0
      add :input, :map
      add :result, :map
      add :error, :map
      add :oban_job_id, :bigint
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:operations, [:document_id])
    create index(:operations, [:user_id])
    create index(:operations, [:status])

    create table(:ocr_results, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :revision_id, references(:document_revisions, type: :binary_id, on_delete: :nilify_all)
      add :languages, {:array, :string}
      add :engine_version, :string
      add :page_confidences, :map
      add :searchable, :boolean, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:ocr_results, [:document_id])
    create index(:ocr_results, [:revision_id])

    create table(:translations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_lang, :string, null: false
      add :target_lang, :string, null: false
      add :mode, :string, null: false

      add :result_revision_id,
          references(:document_revisions, type: :binary_id, on_delete: :nilify_all)

      add :glossary, :map

      timestamps(type: :utc_datetime)
    end

    create index(:translations, [:document_id])
    create index(:translations, [:result_revision_id])

    create table(:translation_cache, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")
      add :key, :string, null: false
      add :source_lang, :string, null: false
      add :target_lang, :string, null: false
      add :output, :text, null: false
      add :provider, :string
      add :token_usage, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:translation_cache, [:key])

    create table(:batch_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :recipe, :map, null: false
      add :status, :string, null: false, default: "queued"
      add :total, :integer, default: 0
      add :completed, :integer, default: 0
      add :failed, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:batch_jobs, [:user_id])

    # ── §5.6 Cloud connections ────────────────────────────────────────────

    create table(:cloud_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :display_name, :string
      add :access_token_encrypted, :binary
      add :refresh_token_encrypted, :binary
      add :expires_at, :utc_datetime
      add :scopes, :string

      timestamps(type: :utc_datetime)
    end

    create index(:cloud_connections, [:user_id])
  end

  def down do
    # Reverse order of up to handle FK dependencies cleanly

    # §5.6
    drop_if_exists table(:cloud_connections)

    # §5.5
    drop_if_exists table(:batch_jobs)
    drop_if_exists index(:translation_cache, [:key])
    drop_if_exists table(:translation_cache)
    drop_if_exists table(:translations)
    drop_if_exists table(:ocr_results)
    drop_if_exists table(:operations)

    # §5.4 — esign depends
    drop_if_exists table(:esign_audit_events)
    drop_if_exists table(:esign_fields)
    drop_if_exists table(:esign_signers)
    drop_if_exists table(:esign_envelopes)
    drop_if_exists table(:digital_signatures)
    drop_if_exists table(:redactions)
    drop_if_exists table(:security_policies)
    drop_if_exists table(:form_submissions)
    drop_if_exists table(:form_fields)

    # §5.3
    drop_if_exists table(:text_edits)
    drop_if_exists table(:annotation_replies)
    drop_if_exists table(:annotations)
    drop_if_exists table(:edit_operations)
  end
end
