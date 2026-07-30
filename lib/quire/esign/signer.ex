defmodule Quire.Esign.Signer do
  @moduledoc """
  A signer on an envelope.
  """

  use Quire.Schema
  import Ecto.Changeset

  schema "esign_signers" do
    field :envelope_id, :binary_id
    field :name, :string
    field :email, :string
    field :order, :integer
    field :role, :string
    field :status, Ecto.Enum, values: [:pending, :viewed, :signed, :declined]
    field :access_token, :string
    field :signed_at, :utc_datetime
    field :ip_address, :string
    field :user_agent, :string

    belongs_to :envelope, Quire.Esign.Envelope, define_field: false
  end

  @doc false
  def changeset(signer, attrs) do
    signer
    |> cast(attrs, [:envelope_id, :name, :email, :order, :role, :access_token, :ip_address, :user_agent])
    |> validate_required([:envelope_id, :name, :email])
    |> validate_length(:name, max: 255)
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
  end

  @doc """
  Updates the signer status, guarding against illegal transitions.
  """
  def put_status(changeset, new_status) do
    current = get_field(changeset, :status) || :pending

    if valid_transition?(current, new_status) do
      put_change(changeset, :status, new_status)
    else
      add_error(changeset, :status, "cannot transition from #{current} to #{new_status}")
    end
  end

  @doc """
  Sets the `signed_at` timestamp.
  """
  def put_signed_at(changeset, timestamp \\ nil) do
    put_change(changeset, :signed_at, timestamp || DateTime.utc_now(:second))
  end

  @doc """
  Returns `true` if the signer status transition is valid.
  """
  def valid_transition?(current, new_state)

  def valid_transition?(:pending, :viewed), do: true
  def valid_transition?(:pending, :declined), do: true
  def valid_transition?(:viewed, :signed), do: true
  def valid_transition?(:viewed, :declined), do: true
  def valid_transition?(:pending, :pending), do: true
  def valid_transition?(_current, _new_state), do: false
end
