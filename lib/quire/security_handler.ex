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

  @doc false
  def check do
    # Skeleton — real implementation will verify Quire.Pdf NIF loads.
    # For now, rely on Quire.Pdf.check/0 for the NIF dependency.
    if function_exported?(Quire.Pdf, :check, 0) do
      Quire.Pdf.check()
    else
      :ok
    end
  end
end
