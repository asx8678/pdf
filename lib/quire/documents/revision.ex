defmodule Quire.Documents.Revision do
  @moduledoc """
  An append-only revision of a document (§5.2).

  `source` is a map that MUST contain a `"storage_ref"` key with the
  `Quire.Storage.Ref.t()` JSON representation — that's how the document
  controller finds the bytes to serve.

  `source` MAY also carry `"url"`, `"filename"` or whatever the creator
  needs to document the origin.
  """
  use Quire.Schema

  schema "document_revisions" do
    field :document_id, :binary_id
    field :label, :string
    field :source, :map, default: %{}

    belongs_to :document, Quire.Documents.Document, define_field: false

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: binary(),
          document_id: binary(),
          label: String.t() | nil,
          source: map(),
          inserted_at: DateTime.t() | nil
        }

  @doc """
  Extract the `Storage.Ref` from a revision's source map.

  Returns `nil` when the revision has no storage ref or the ref is malformed.

  Source maps are stored as JSON (`Ecto` `:map` column), so the ref keys
  arrive back as strings — `struct/2` only accepts atom keys, so the map is
  translated explicitly.
  """
  @spec storage_ref(t()) :: Quire.Storage.Ref.t() | nil
  def storage_ref(%__MODULE__{} = revision) do
    case revision.source do
      %{"storage_ref" => ref_map} when is_map(ref_map) -> ref_from_map(ref_map)
      %{storage_ref: ref_map} when is_map(ref_map) -> ref_from_map(ref_map)
      _ -> nil
    end
  end

  # Rebuild a Ref from a JSON-decoded (string-keyed) or native (atom-keyed)
  # map. Only the struct fields are read; unknown keys are ignored.
  defp ref_from_map(ref_map) do
    Enum.reduce(
      [:adapter, :key, :name, :content_type, :byte_size, :meta],
      %Quire.Storage.Ref{},
      fn field, acc ->
        value = Map.get(ref_map, Atom.to_string(field)) || Map.get(ref_map, field)
        Map.put(acc, field, value)
      end
    )
  end
end
