defmodule Quire.Repo.Migrations.CreateCoreAndDocumentTables do
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
    # ── user_settings (§5.1) ──────────────────────────────────────────────

    create table(:user_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :theme, :string, default: "light"
      add :default_zoom, :float, default: 1.0
      add :default_view_mode, :string, default: "continuous"
      add :ruler_visible, :boolean, default: false
      add :grid_visible, :boolean, default: false
      add :qat_items, :map
      add :recent_limit, :integer, default: 20
      add :ocr_default_lang, :string, default: "eng"
      add :measurement_unit, :string, default: "mm"
      add :autosave_enabled, :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_settings, [:user_id])

    # ── licenses (§5.1) ──────────────────────────────────────────────────

    create table(:licenses, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :tier, :string, null: false, default: "trial"
      add :seats, :integer, null: false, default: 1
      add :activated_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :activation_key, :string

      timestamps(type: :utc_datetime)
    end

    create index(:licenses, [:user_id])

    # ── documents (§5.2) ──────────────────────────────────────────────────
    #
    # current_revision_id FK is added below after document_revisions exists
    # to avoid a circular-reference ordering problem.

    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :string, null: false, default: "Untitled"
      add :source_format, :string
      add :current_revision_id, :binary_id
      add :page_count, :integer, default: 0
      add :metadata, :map

      timestamps(type: :utc_datetime)
    end

    create index(:documents, [:user_id])

    # ── document_revisions (§5.2) ─────────────────────────────────────────

    create table(:document_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :label, :string
      add :source, :map

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:document_revisions, [:document_id])

    # FK from documents.current_revision_id → document_revisions.id

    alter table(:documents) do
      modify :current_revision_id,
             references(:document_revisions, type: :binary_id, on_delete: :nilify_all)
    end

    # ── document_pages (§5.2) ─────────────────────────────────────────────

    create table(:document_pages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :revision_id, references(:document_revisions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :page_index, :integer, null: false
      add :width, :float
      add :height, :float
      add :thumbnail_ref, :string

      timestamps(type: :utc_datetime)
    end

    create index(:document_pages, [:revision_id])
    create index(:document_pages, [:revision_id, :page_index], unique: true)

    # ── recents (§5.2) ────────────────────────────────────────────────────

    create table(:recents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :opened_at, :utc_datetime
    end

    create index(:recents, [:user_id])
    create index(:recents, [:user_id, :opened_at])
    create unique_index(:recents, [:user_id, :document_id])

    # ── document_page_text (§5.2) — server-side search fallback ───────────
    #
    # search is a GENERATED ALWAYS AS STORED tsvector — explicitly NOT
    # VIRTUAL (§3.7), because virtual columns cannot be indexed.
    # The GIN index enables fast full-text search via websearch_to_tsquery.

    create table(:document_page_text, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :revision_id, references(:document_revisions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :page_index, :integer, null: false
      add :content, :text, null: false

      add :search,
          :tsvector,
          null: false,
          generated: "ALWAYS AS (to_tsvector('simple', content)) STORED"

      add :spans, :map

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:document_page_text, [:revision_id])
    create index(:document_page_text, [:revision_id, :page_index], unique: true)
    create index(:document_page_text, [:search], using: :gin)
  end

  def down do
    # document_page_text (depends on revisions)
    drop_if_exists table(:document_page_text)

    # recents (depends on users, documents)
    drop_if_exists table(:recents)

    # document_pages (depends on revisions)
    drop_if_exists table(:document_pages)

    # Drop FK from documents → document_revisions before dropping revisions
    drop_if_exists constraint(:documents, "documents_current_revision_id_fkey")

    # document_revisions (depends on documents)
    drop_if_exists table(:document_revisions)

    # documents (depends on users)
    drop_if_exists table(:documents)

    # licenses (depends on users)
    drop_if_exists table(:licenses)

    # user_settings (depends on users)
    drop_if_exists table(:user_settings)
  end
end
