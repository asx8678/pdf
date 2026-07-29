defmodule Quire.Accounts.SigningCredential do
  @moduledoc """
  Stores a user's signing certificate (PKCS#12 keystore) and its
  passphrase, encrypted at rest via `Cloak`.

  The keystore bytes themselves live in the Storage layer and are
  referenced by `keystore_ref_key`. Only this key column is persisted;
  the bytes are fetched on demand through `Quire.Storage`.

  ## Sudo gating

  Every mutation of this table must be preceded by a sudo-mode check
  (§11.1). See `Quire.Accounts.sudo_mode?/2`.
  """

  use Quire.Schema

  alias Quire.Accounts.SigningCredential.Passphrase

  schema "signing_credentials" do
    field :user_id, :binary_id
    field :label, :string
    field :subject, :string
    field :issuer, :string
    field :serial, :string
    field :not_after, :utc_datetime
    field :keystore_ref_key, :string
    field :passphrase_encrypted, Passphrase

    timestamps()
  end

  @doc false
  def changeset(credential, attrs) do
    credential
    |> Ecto.Changeset.cast(attrs, [
      :label,
      :subject,
      :issuer,
      :serial,
      :not_after,
      :keystore_ref_key,
      :passphrase_encrypted
    ])
    |> Ecto.Changeset.validate_required([:label, :keystore_ref_key, :passphrase_encrypted])
    |> Ecto.Changeset.unique_constraint(:label, name: :signing_credentials_user_id_label_index)
  end
end
