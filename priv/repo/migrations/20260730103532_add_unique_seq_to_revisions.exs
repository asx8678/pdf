defmodule Quire.Repo.Migrations.AddUniqueSeqToRevisions do
  use Ecto.Migration

  def up do
    # Branch-on-undo semantics (§7.4): after undoing rev N to rev N-1 and
    # applying a new op, the result is rev N+1 with parent_revision_id = N-1
    # (a branch). seq numbers are per-document and assigned monotonically —
    # branching means seq is no longer dense. The UNIQUE constraint enforces
    # that no two revisions share the same seq for the same document, which
    # would violate append-only and break Compare's two-revision diff.
    create unique_index(:document_revisions, [:document_id, :seq],
             name: :document_revisions_document_id_seq_unique
           )
  end

  def down do
    drop unique_index(:document_revisions, [:document_id, :seq],
           name: :document_revisions_document_id_seq_unique
         )
  end
end
