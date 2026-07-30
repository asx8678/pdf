defmodule Quire.Esign.Envelope do
  @moduledoc """
  A signature envelope — a document sent to one or more signers for signing.

  ## States

    `:draft` → `:sent` → (`:partially_signed` → `:completed` | `:declined` | `:voided` | `:expired`)
  """

  use Quire.Schema
  import Ecto.Changeset

  schema "esign_envelopes" do
    field :document_id, :binary_id
    field :owner_id, :binary_id
    field :subject, :string
    field :message, :string

    field :status, Ecto.Enum,
      values: [:draft, :sent, :partially_signed, :completed, :declined, :voided, :expired]

    field :signing_mode, Ecto.Enum, values: [:sequential, :parallel], default: :sequential
    field :expires_at, :utc_datetime
    field :sent_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :last_reminded_at, :utc_datetime

    has_many :signers, Quire.Esign.Signer
    has_many :fields, Quire.Esign.Field

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(envelope, attrs) do
    envelope
    |> cast(attrs, [:document_id, :owner_id, :subject, :message, :expires_at, :signing_mode])
    |> validate_required([:document_id, :owner_id])
    |> validate_length(:subject, max: 255)
  end

  @doc """
  Updates the envelope status, guarding against illegal transitions.
  """
  def put_status(changeset, new_status) do
    current = get_field(changeset, :status) || :draft

    if valid_transition?(current, new_status) do
      put_change(changeset, :status, new_status)
    else
      add_error(changeset, :status, "cannot transition from #{current} to #{new_status}")
    end
  end

  @doc """
  Sets the `sent_at` timestamp.
  """
  def put_sent_at(changeset) do
    put_change(changeset, :sent_at, DateTime.utc_now(:second))
  end

  @doc """
  Sets the `completed_at` timestamp.
  """
  def put_completed_at(changeset) do
    put_change(changeset, :completed_at, DateTime.utc_now(:second))
  end

  @doc """
  Returns `true` if the transition from `current` to `new_state` is valid.
  """
  def valid_transition?(current, new_state)

  def valid_transition?(:draft, :sent), do: true
  def valid_transition?(:sent, :partially_signed), do: true
  def valid_transition?(:sent, :declined), do: true
  def valid_transition?(:sent, :voided), do: true
  def valid_transition?(:sent, :expired), do: true
  def valid_transition?(:partially_signed, :completed), do: true
  def valid_transition?(:partially_signed, :declined), do: true
  def valid_transition?(:partially_signed, :voided), do: true
  def valid_transition?(:partially_signed, :expired), do: true
  def valid_transition?(:draft, :draft), do: true
  def valid_transition?(_current, _new_state), do: false

  @doc """
  Returns all valid transitions as a map.
  """
  def transitions do
    %{
      draft: [:sent, :draft],
      sent: [:partially_signed, :declined, :voided, :expired],
      partially_signed: [:completed, :declined, :voided, :expired],
      completed: [],
      declined: [],
      voided: [],
      expired: []
    }
  end
end
