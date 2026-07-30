defmodule Quire.Accounts.License do
  @moduledoc """
  A user's license record, tracking tier and activation state (§11.2).

  There is at most one active license per user (enforced by unique index on
  `user_id`).  The `tier` field determines which features `Quire.Licensing`
  gates against.
  """

  use Quire.Schema
  import Ecto.Changeset

  schema "licenses" do
    belongs_to :user, Quire.Accounts.User
    field :tier, :string, default: "trial"
    field :seats, :integer, default: 1
    field :activated_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :activation_key, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(license, attrs) do
    license
    |> cast(attrs, [:tier, :seats, :activated_at, :expires_at, :activation_key])
    |> validate_required([:tier])
    |> validate_inclusion(:tier, ["trial", "standard", "premium", "business"])
    |> validate_number(:seats, greater_than: 0)
  end
end
