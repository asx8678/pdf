defmodule Quire.Documents.Document do
  @moduledoc """
  A user-owned document (§5.2).

  `current_revision_id` points to the latest `DocumentRevision` — the one
  the viewer should load. Every server-side mutation creates a new revision;
  the journal (§7.4) tracks what happened between them.
  """
  use Quire.Schema

  schema "documents" do
    field :user_id, :binary_id
    field :title, :string, default: "Untitled"
    field :source_format, :string
    field :current_revision_id, :binary_id
    field :page_count, :integer, default: 0
    field :metadata, :map, default: %{}

    has_many :revisions, Quire.Documents.Revision, foreign_key: :document_id

    timestamps(type: :utc_datetime)
  end
end
