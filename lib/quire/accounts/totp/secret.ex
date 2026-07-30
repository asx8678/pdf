defmodule Quire.Accounts.Totp.Secret do
  @moduledoc """
  An `Ecto.Type` that encrypts the TOTP secret at rest via `Quire.Vault`.

  The column is `:binary` (AES-GCM ciphertext). On load the plaintext is
  returned as a string; on dump it is encrypted before write.
  """

  use Cloak.Ecto.Type, vault: Quire.Vault
end
