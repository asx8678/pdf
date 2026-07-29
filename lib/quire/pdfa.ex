defmodule Quire.PdfA do
  @moduledoc """
  PDF/A conversion and conformance reporting behaviour (§7.2).

  Operates over `Quire.Pdf` for structure writes. Conformance is
  best-effort — the module reports what it fixed and what it couldn't.
  """

  @doc """
  Converts a PDF to PDF/A format.

  Returns conformance report as a map with `:level`, `:fixes`, and
  optional `:warnings`.
  """
  @callback convert(pdf_bytes :: binary(), opts :: keyword()) ::
              {:ok, binary(), map()} | {:error, term()}

  @doc """
  Validates PDF/A conformance without modifying the document.

  Returns a map with `:conformant` (boolean), `:level`, and `:issues`.
  """
  @callback validate(pdf_bytes :: binary()) :: {:ok, map()} | {:error, term()}
end
