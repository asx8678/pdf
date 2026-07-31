defmodule Quire.Ecto.JsonArray do
  @moduledoc """
  Ecto type for a `jsonb` column that stores a JSON array (list) of maps.

  `document_page_text.spans` holds the per-span bounding boxes as a list of
  maps (`Render.extract_text/2` shape). The column is `jsonb` (migration
  `add :spans, :map`), which accepts JSON arrays fine — but Ecto's stock
  `:map` type rejects lists on dump/load, so `TextExtractWorker`'s
  `insert_all` raised `does not match type :map`. This type bridges the gap:
  the DB keeps a jsonb array, the schema exposes a plain Elixir list.
  """

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(term) when is_list(term), do: {:ok, term}
  def cast(_), do: :error

  @impl true
  def load(term) when is_list(term), do: {:ok, term}
  def load(_), do: :error

  @impl true
  def dump(term) when is_list(term), do: {:ok, term}
  def dump(_), do: :error
end
