defmodule Quire.Pades do
  @moduledoc """
  Signing and validation behaviour — PAdES (§7.2, §11).

  Operates over `Quire.Pdf` for structure writes; validation checks signatures
  against known certificates.
  """

  @doc """
  Signs a PDF document.

  `pdf_bytes` is the document to sign. `signer` is a map with `:certificate`,
  `:private_key` and optional `:passphrase`. Returns signed PDF bytes.
  """
  @callback sign(pdf_bytes :: binary(), signer :: map(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Verifies all signatures on a PDF.

  Returns a list of signature verification results, each with `:valid`,
  `:signer`, `:timestamp` and optional `:warnings`.
  """
  @callback verify(pdf_bytes :: binary()) :: {:ok, list(map())} | {:error, term()}
end
