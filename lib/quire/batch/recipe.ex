defmodule Quire.Batch.Recipe do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "recipes" do
    field :name, :string
    field :steps, Quire.Ecto.JsonArray, default: []
    belongs_to :user, Quire.Accounts.User, type: :binary_id

    timestamps()
  end

  @doc false
  def changeset(recipe, attrs) do
    recipe
    |> cast(attrs, [:name, :steps])
    |> validate_required([:name, :steps])
    |> validate_length(:name, min: 1, max: 80)
    |> unique_constraint([:user_id, :name])
  end
end
