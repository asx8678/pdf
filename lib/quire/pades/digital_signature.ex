defmodule Quire.Pades.DigitalSignature do
  @moduledoc """
  A stored result of a PAdES signing operation (plan3.md §5.4, lines 741-752).

  `pades_level` is one of `:b_b | :b_t | :b_lt` (stored as a string). `:b_b`
  is a basic (BES/EPES) signature; `:b_t` additionally embeds an RFC 3161
  timestamp in the CMS profile. `validation_status` holds a JSON map of the
  post-sign validation result (e.g. signature cryptographic validity, whether
  the timestamp token verified, whether the signature survives page
  rotation).
  """

  use Quire.Schema

  schema "digital_signatures" do
    field :document_id, :binary_id
    field :revision_id, :binary_id
    field :signer_name, :string
    field :signer_email, :string
    field :certificate_subject, :string
    field :certificate_issuer, :string
    field :serial, :string
    field :signed_at, :utc_datetime
    field :tsa_url, :string
    field :pades_level, :string
    field :field_name, :string
    field :validation_status, :map, default: %{}

    timestamps()
  end

  @level_atoms [:b_b, :b_t, :b_lt]

  @doc false
  def changeset(signature, attrs) do
    signature
    |> Ecto.Changeset.cast(attrs, [
      :document_id,
      :revision_id,
      :signer_name,
      :signer_email,
      :certificate_subject,
      :certificate_issuer,
      :serial,
      :signed_at,
      :tsa_url,
      :pades_level,
      :field_name,
      :validation_status
    ])
    |> Ecto.Changeset.validate_required([:document_id, :revision_id, :pades_level])
    |> Ecto.Changeset.validate_inclusion(:pades_level, Enum.map(@level_atoms, &to_string/1))
  end

  @doc "Human-readable signed-at as UTC ISO8601, or nil."
  def signed_at_iso(%__MODULE__{signed_at: nil}), do: nil
  def signed_at_iso(%__MODULE__{signed_at: dt}), do: DateTime.to_iso8601(dt)
end