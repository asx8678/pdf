defmodule Quire.SecurityHandler do
  @moduledoc """
  Encryption/decryption behaviour — document security (§7.2, §11).

  Handles `/Encrypt` dictionary operations over `Quire.Pdf`. Each operation
  works on raw PDF bytes.
  """

  @doc """
  Encrypts a PDF with the given password or certificate.

  Returns encrypted PDF bytes. The password is never persisted.
  """
  @callback encrypt(pdf_bytes :: binary(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Decrypts a PDF with the given password or key.

  Returns decrypted PDF bytes. The password is zeroed after use.
  """
  @callback decrypt(pdf_bytes :: binary(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Returns whether the PDF is encrypted and the encryption method.
  """
  @callback info(pdf_bytes :: binary()) :: {:ok, map()} | {:error, term()}
end
