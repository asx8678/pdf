defmodule Quire.Documents.AnnotationReply do
  @moduledoc """
  A reply thread on an annotation.

  Stores reply content linked to the parent annotation. Replies are
  persisted independently of the PDF save cycle — they are not embedded
  in the document but serve as collaborative metadata visible in the
  annotation panel.
  """
  use Quire.Schema

  schema "annotation_replies" do
    belongs_to :annotation, Quire.Documents.Annotation
    belongs_to :author, Quire.Accounts.User, foreign_key: :author_id
    field :content, :string
    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc false
  def changeset(reply, attrs) do
    reply
    |> Ecto.Changeset.cast(attrs, [:annotation_id, :author_id, :content])
    |> Ecto.Changeset.validate_required([:annotation_id, :author_id, :content])
  end
end
