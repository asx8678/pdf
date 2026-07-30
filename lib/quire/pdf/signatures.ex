defmodule Quire.Pdf.Signatures do
  @moduledoc """
  Detection of digital signatures in PDF byte streams (§7.4).

  Scans raw PDF bytes for signature-related entries without requiring a full
  parse of the object graph.  This is intentionally lightweight — it finds
  `/ByteRange` and `/Sig` markers to produce a count of existing signatures,
  which is enough for the save-time guard that warns the user before a
  full re-serialisation destroys them.

  ## Incremental save

  When the document has signatures, the correct save strategy is an
  incremental update (`Quire.Pdf.incremental_save/1`) that reproduces the
  original bytes verbatim and appends only changed objects, keeping every
  existing `/ByteRange` valid.  Full re-serialisation (`Quire.Pdf.save/1`
  or a client-side save from pdf-lib) rewrites the file and invalidates
  all signatures.
  """

  @pdf_header_magic <<37, 80, 68, 70, 45>>

  @doc """
  Detects existing digital signatures in PDF bytes.

  Returns the number of distinct signature indicators found (`/ByteRange`
  entries and `/Type /Sig` dictionaries).  A count of zero means no
  signatures were detected.

  ## Examples

      {:ok, 0} = Quire.Pdf.Signatures.detect(plain_pdf_bytes)
      {:ok, 1} = Quire.Pdf.Signatures.detect(signed_pdf_bytes)
  """
  @spec detect(binary()) :: {:ok, non_neg_integer()} | {:error, :invalid_pdf}
  def detect(pdf_bytes) when is_binary(pdf_bytes) do
    if valid_pdf?(pdf_bytes) do
      {:ok, count_signatures(pdf_bytes)}
    else
      {:error, :invalid_pdf}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp valid_pdf?(<<@pdf_header_magic, _rest::binary>>), do: true
  defp valid_pdf?(_), do: false

  defp count_signatures(bytes) do
    # Every PAdES signature dictionary MUST contain a /ByteRange array
    # with four integers defining the byte ranges the signature covers.
    # Counting /ByteRange is the most reliable single indicator — every
    # signed signature has exactly one, and nothing else in the spec
    # requires it.
    byte_range_count = count_occurrences(bytes, "/ByteRange")

    # Also count /Type /Sig dictionaries for signatures that may use a
    # non-standard /ByteRange syntax or are still being composed.
    type_sig_count = count_occurrences(bytes, "/Type /Sig")

    # Take the larger of the two: /ByteRange is the ground truth for
    # completed signatures, /Type /Sig catches fields mid-creation.
    max(byte_range_count, type_sig_count)
  end

  defp count_occurrences(binary, pattern) do
    binary
    |> :binary.matches(pattern)
    |> length()
  end
end
