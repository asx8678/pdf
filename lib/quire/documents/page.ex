defmodule Quire.Documents.Page do
  @moduledoc """
  A single page of a document revision (§5.2).

  Each revision has one `Page` row per page; `page_index` is zero-based.
  `thumbnail_ref` is a `Quire.Storage.Ref` key serialised as a string for
  the thumbnail image PNG.
  """
  use Quire.Schema

  schema "document_pages" do
    field :revision_id, :binary_id
    field :page_index, :integer
    field :width, :float
    field :height, :float
    field :thumbnail_ref, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: binary(),
          revision_id: binary(),
          page_index: non_neg_integer(),
          width: float() | nil,
          height: float() | nil,
          thumbnail_ref: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end
