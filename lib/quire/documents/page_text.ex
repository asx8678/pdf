defmodule Quire.Documents.PageText do
  @moduledoc """
  Per-page extracted text for a document revision (§5.2).

  `content` is the raw page text concatenated from all spans. `search` is a
  generated tsvector column for server-side full-text search fallback (T-048).
  `spans` is a JSON map of per-span bounding boxes returned by `Render.extract_text/2`.
  """
  use Quire.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}

  schema "document_page_text" do
    field :revision_id, :binary_id
    field :page_index, :integer
    field :content, :string
    field :spans, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: binary(),
          revision_id: binary(),
          page_index: non_neg_integer(),
          content: String.t(),
          spans: map() | nil,
          inserted_at: DateTime.t() | nil
        }
end
