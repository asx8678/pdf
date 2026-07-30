defmodule Quire.Esign.AuditEvent do
  @moduledoc """
  An audit trail event recorded during the envelope lifecycle (§9.9).

  Every event is associated with an envelope and optionally with a
  specific signer. The `event` field identifies the type and `metadata`
  carries event-specific details such as IP address, user agent, and
  timestamp.
  """

  use Quire.Schema
  import Ecto.Changeset

  schema "esign_audit_events" do
    field :envelope_id, :binary_id
    field :signer_id, :binary_id
    field :event, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:envelope_id, :signer_id, :event, :metadata, :occurred_at])
    |> validate_required([:envelope_id, :event, :occurred_at])
  end
end
