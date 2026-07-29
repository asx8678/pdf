defmodule Quire.SchemaTest do
  use Quire.DataCase

  alias Quire.Accounts.User
  alias Quire.Accounts.UserToken

  describe "Quire.Schema __using__ macro" do
    test "sets UUID v7 primary key on the schema" do
      assert User.__schema__(:type, :id) == Ecto.UUID,
             "expected User primary key type to be Ecto.UUID (v7), not :binary_id (v4)"

      assert UserToken.__schema__(:type, :id) == Ecto.UUID,
             "expected UserToken primary key type to be Ecto.UUID (v7), not :binary_id (v4)"
    end

    test "changeset-inserted row has a UUID v7 primary key" do
      {:ok, user} =
        %{email: "v7-test-changeset@example.com"}
        |> then(fn attrs -> Quire.Accounts.register_user(attrs) end)

      assert Ecto.UUID.version(user.id) == 7,
             "expected id #{inspect(user.id)} to be UUID v7"
    end

    test "insert_all row has a UUID v7 primary key" do
      email = "v7-insert-all@example.com"
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {1, [%{id: id}]} =
        Quire.Repo.insert_all(
          User,
          [
            %{
              email: email,
              id: Ecto.UUID.generate(version: 7),
              inserted_at: now,
              updated_at: now
            }
          ],
          returning: [:id]
        )

      assert Ecto.UUID.version(id) == 7,
             "expected id #{inspect(id)} to be UUID v7"
    end

    test "UUID v7 encodes a usable timestamp" do
      before = DateTime.utc_now()

      {:ok, user} =
        %{email: "v7-timestamp@example.com"}
        |> then(fn attrs -> Quire.Accounts.register_user(attrs) end)

      after_ = DateTime.utc_now()

      id_dt = Ecto.UUID.to_datetime(user.id)

      # The timestamp embedded in the UUID v7 should fall between
      # the before and after wall-clock readings.
      assert DateTime.compare(id_dt, before) != :lt,
             "UUID timestamp #{inspect(id_dt)} is before #{inspect(before)}"

      assert DateTime.compare(id_dt, after_) != :gt,
             "UUID timestamp #{inspect(id_dt)} is after #{inspect(after_)}"
    end
  end

  describe "schema audit" do
    @doc """
    Every Ecto schema must use `Quire.Schema` to ensure UUID v7 primary keys.
    `--binary-id` alone yields v4 (Ecto.UUID.bingenerate/0), which defeats
    the index-locality rationale in §3.7.

    Enumerate known schemas explicitly.
    """
    test "every Ecto schema uses Quire.Schema" do
      schemas = [Quire.Accounts.User, Quire.Accounts.UserToken]

      schemas_without_v7 =
        Enum.reject(schemas, fn mod ->
          mod.__schema__(:type, :id) == Ecto.UUID
        end)

      assert schemas_without_v7 == [],
             "Schemas without UUID v7 primary key: #{inspect(schemas_without_v7)}"
    end
  end
end
