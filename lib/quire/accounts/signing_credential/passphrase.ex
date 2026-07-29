defmodule Quire.Accounts.SigningCredential.Passphrase do
  @moduledoc """
  An `Ecto.Type` that encrypts the signing passphrase at rest via `Quire.Vault`.

  The column is `:binary` (the AES-GCM ciphertext produced by Cloak). On load
  the plaintext is returned as a string; on dump it is encrypted before write.
  """

  use Cloak.Ecto.Type, vault: Quire.Vault
end
