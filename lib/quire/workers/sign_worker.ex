defmodule Quire.Workers.SignWorker do
  @moduledoc """
  Oban worker that performs a PAdES digital signature operation.

  ## Configuration

  `max_attempts: 1` — per plan3.md R-04 (line 2665), never silently re-sign.
  If the job fails, it goes to the dead-letter queue rather than retrying.
  Cryptographic operations must not be re-attempted — a failure must be
  visible and resolved by a human.

  ## Job args

    * `"document_id"` — the document to sign (binary_id / UUID string)
    * `"revision_id"` — the revision to sign (binary_id / UUID string)
    * `"pdf_path"` — path to the PDF bytes in storage
    * `"signer_name"` — signer display name
    * `"signer_email"` — signer email
    * `"certificate_der"` — Base64-encoded DER X.509 certificate
    * `"private_key_der"` — Base64-encoded DER PKCS#8 private key
    * `"algorithm"` — `"rsa"` or `"ecdsa"`
    * `"pades_level"` — `"b_b"` or `"b_t"`
    * `"field_name"` — signature field name
    * `"field_rect"` — `[x0, y0, x1, y1]` in PDF points
    * `"page_index"` — zero-based page number
    * `"user_id"` — the user who initiated signing
  """

  use Oban.Worker,
    queue: :secure,
    max_attempts: 1

  require Logger

  alias Quire.{Repo, Pades}
  alias Quire.Pades.DigitalSignature

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    document_id = args["document_id"]
    revision_id = args["revision_id"]
    pdf_path = args["pdf_path"]
    _signer_name = args["signer_name"] || "Unknown"
    _signer_email = args["signer_email"] || ""
    pades_level = to_atom(args["pades_level"], :b_b)

    with {:ok, pdf_bytes} <- read_pdf(pdf_path),
         {:ok, signer} <- build_signer(args),
         {:ok, result} <-
           Pades.sign(pdf_bytes, signer,
             pades_level: pades_level,
             field_name: args["field_name"] || "Signature1",
             field_rect: parse_rect(args["field_rect"]),
             page_index: parse_index(args["page_index"]),
             reason: args["reason"] || "",
             location: args["location"] || "",
             contact_info: args["contact_info"] || ""
           ),
         :ok <- write_pdf(pdf_path, result.signed_bytes),
         {:ok, sig_row} <- store_signature(document_id, revision_id, signer, result, args) do
      Logger.info("PAdES #{pades_level} signature created: #{sig_row.id}")

      {:ok, %{signature_id: sig_row.id, pades_level: pades_level}}
    end
  end

  defp read_pdf(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:pdf_read, reason}}
    end
  end

  defp build_signer(args) do
    cert_b64 = args["certificate_der"]
    key_b64 = args["private_key_der"]
    algorithm = to_atom(args["algorithm"], :rsa)

    with {:ok, cert_der} <- decode_b64(cert_b64, "certificate"),
         {:ok, key_der} <- decode_b64(key_b64, "private key") do
      {:ok,
       %{
         certificate_der: cert_der,
         private_key_der: key_der,
         algorithm: algorithm
       }}
    end
  end

  defp decode_b64(nil, _label), do: {:error, :missing_key_material}

  defp decode_b64(b64, label) do
    case Base.decode64(b64) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, {:bad_base64, label}}
    end
  end

  defp parse_rect(nil), do: [72, 72, 216, 144]
  defp parse_rect(rect) when is_list(rect), do: Enum.map(rect, &to_number/1)

  defp parse_index(nil), do: 0
  defp parse_index(idx) when is_integer(idx), do: idx

  defp parse_index(idx) when is_binary(idx) do
    case Integer.parse(idx) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_number(n) when is_number(n), do: n

  defp to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp write_pdf(path, bytes) do
    case File.write(path, bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, {:pdf_write, reason}}
    end
  end

  defp store_signature(document_id, revision_id, signer, result, args) do
    # Extract certificate info for the digital_signatures row
    cert_der = signer.certificate_der
    {subject, issuer, serial} = extract_cert_info(cert_der)

    attrs = %{
      document_id: document_id,
      revision_id: revision_id,
      signer_name: args["signer_name"] || "Unknown",
      signer_email: args["signer_email"] || "",
      certificate_subject: subject,
      certificate_issuer: issuer,
      serial: serial,
      signed_at: DateTime.utc_now(:second),
      tsa_url: tsa_url(args),
      pades_level: to_string(args["pades_level"] || "b_b"),
      field_name: args["field_name"] || "Signature1",
      validation_status: %{
        valid: true,
        signature_hex: result.signature_hex,
        pades_level: result.pades_level
      }
    }

    %DigitalSignature{}
    |> DigitalSignature.changeset(attrs)
    |> Repo.insert()
  end

  defp extract_cert_info(cert_der) do
    decoded = :public_key.pkix_decode_cert(cert_der, :plain)
    tbs = elem(decoded, 1)
    serial = elem(tbs, 2) |> Integer.to_string()

    subject = tuple_to_dn(elem(tbs, 6))
    issuer = tuple_to_dn(elem(tbs, 4))

    {subject, issuer, serial}
  rescue
    _ -> {"Unknown", "Unknown", "0"}
  end

  defp tuple_to_dn({:rdnSequence, rdns}) when is_list(rdns) do
    rdns
    |> Enum.map(fn {:AttributeTypeAndValue, _oid, value} ->
      case value do
        {tag, s} when tag in [:printableString, :utf8String, :ia5String, :teletexString] ->
          to_string(s)

        _ ->
          ""
      end
    end)
    |> Enum.join(", ")
  end

  defp tuple_to_dn(_), do: "Unknown"

  defp tsa_url(args) do
    args["tsa_url"] || Application.get_env(:quire, :pades, [])[:tsa_url] || nil
  end

  defp to_atom(nil, default), do: default
  defp to_atom(s, _default) when is_atom(s), do: s

  defp to_atom(s, default) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> default
  end
end
