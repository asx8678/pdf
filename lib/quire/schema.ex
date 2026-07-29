defmodule Quire.Schema do
  @moduledoc """
  Shared `__using__` macro for every Ecto schema in the project.

  Sets the primary key to a **UUID v7** (not v4). `:binary_id` autogenerates v4
  in the application, which scatters B-tree inserts and defeats the index-locality
  rationale in §3.7. `Ecto.UUID`'s type is `:uuid` rather than `:binary_id`, so
  Ecto omits the id from the INSERT and the column's `DEFAULT uuidv7()` fires
  database-side as a backstop.

  Foreign keys use `:binary_id` (Postgres `uuid`), matching what `mix phx.gen.html`
  and `phx.gen.live` emit under `--binary-id`.

  ## Usage

      defmodule Quire.Accounts.User do
        use Quire.Schema

        schema "users" do
          field :email, :string
          # ...
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}
      @foreign_key_type :binary_id
    end
  end
end
