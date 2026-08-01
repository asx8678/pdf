defmodule Quire.Pades.Tsa do
  @moduledoc """
  RFC 3161 Time-Stamp Protocol (TSP) client.

  Builds a `TimeStampReq`, POSTs it over `:req` to a configured TSA URL, parses
  the `TimeStampResp`, and **verifies** the returned `TimeStampToken` per
  RFC 3161 before it is trusted:

    * the status is `granted` (0) or `grantedWithMods` (1),
    * the token's `messageImprint` equals the digest we requested (so the TSA
      timestamped exactly *our* bytes, not a substitute),
    * the embedded CMS `SignedData` over the `TSTInfo` carries a valid
      content-integrity signature (checked against the embedded signer
      certificate; handles both bare-content and signed-Attribute signatures).

  The request is a real Req HTTP client (`req` dependency). The TSA URL is
  resolved through the application environment / runtime config
  (`:quire, :pades, :tsa_url`), with a per-call override for tests.

  Provider-agnostic: any RFC 3161-conformant TSA (DigiCert, Sectigo, FreeTSA,
  or a local in-test server) works.
  """

  alias Quire.Pades.Cms

  @oid_sha256 {2, 16, 840, 1, 101, 3, 4, 2, 1}
  @oid_signed_data {1, 2, 840, 113_549, 1, 7, 2}
  @oid_message_digest {1, 2, 840, 113_549, 1, 9, 4}

  @type ts_info :: %{
          gen_time: String.t() | nil,
          message_imprint: binary(),
          serial_number: non_neg_integer() | nil,
          policy: tuple() | nil,
          digest_algorithm: tuple(),
          signature_valid: boolean()
        }

  @doc """
  Fetch a RFC 3161 timestamp token for `content_hash` over Req.

  Returns `{:ok, %{token: der_binary, tst_info: ts_info}}` or `{:error, reason}`.

  Options:
    * `:tsa_url` — override the configured TSA URL (required in tests)
    * `:req_opts` — extra `Req` options
  """
  @spec request(binary(), keyword()) ::
          {:ok, %{token: binary(), tst_info: ts_info()}} | {:error, term()}
  def request(content_hash, opts \\ []) do
    tsa_url = Keyword.get(opts, :tsa_url) || Application.get_env(:quire, :pades, %{})[:tsa_url]

    with {:ok, tsa_url} <- require_url(tsa_url),
         {:ok, req_der, imprint} <- build_request(content_hash),
         {:ok, resp_der} <- post(tsa_url, req_der, opts),
         {:ok, status, token_der} <- parse_response(resp_der),
         :ok <- assert_status(status),
         {:ok, tst_info} <- verify(token_der, imprint) do
      {:ok, %{token: token_der, tst_info: tst_info}}
    end
  end

  defp require_url(nil), do: {:error, :tsa_not_provided}
  defp require_url(""), do: {:error, :tsa_not_provided}
  defp require_url(url) when is_binary(url), do: {:ok, url}
  defp require_url(_), do: {:error, :tsa_not_provided}

  # ── Request ────────────────────────────────────────────────────────────

  @doc false
  def build_request(content_hash) do
    imprint =
      Cms.encode_sequence([
        Cms.encode_sequence([Cms.encode_oid(@oid_sha256), Cms.encode_null()]),
        Cms.encode_octet_string(content_hash)
      ])

    req =
      Cms.encode_sequence([
        Cms.encode_integer(1),
        imprint,
        Cms.encode_boolean(true)
      ])

    {:ok, req, content_hash}
  end

  defp post(tsa_url, request_der, opts) do
    response =
      Req.new(Keyword.get(opts, :req_opts, []))
      |> Req.post!(
        url: tsa_url,
        headers: [{"content-type", "application/timestamp-query"}],
        body: request_der
      )

    case response do
      %{status: 200, body: body} when is_binary(body) -> {:ok, body}
      %{status: status} -> {:error, {:tsa_http_status, status}}
    end
  rescue
    e -> {:error, {:tsa_http_error, Exception.message(e)}}
  end

  # ── Response parsing ────────────────────────────────────────────────────

  @doc """
  Parse a `TimeStampResp` DER.

  Returns `{:ok, status, token_der}`; status is `:granted` or
  `:granted_with_mods`; token_der is the raw TimeStampToken (a ContentInfo).
  """
  def parse_response(resp_der) when is_binary(resp_der) do
    with {{0x30, body}, _} <- Cms.decode_tlv(resp_der),
         {{0x30, status_info}, after_status} <- Cms.decode_tlv(body),
         {:ok, status} <- read_pki_status(status_info),
         {:ok, token} <- read_token_der(after_status) do
      {:ok, status, token}
    end
  end

  defp read_pki_status(<<0x02, _len, val::binary>>) do
    case :binary.decode_unsigned(val) do
      0 -> {:ok, :granted}
      1 -> {:ok, :granted_with_mods}
      other -> {:error, {:tsa_status, other}}
    end
  end

  defp read_pki_status(_), do: {:error, :invalid_response}

  defp assert_status(:granted), do: :ok
  defp assert_status(:granted_with_mods), do: :ok

  @doc false
  def read_token_der(bin) do
    case split_tlv(bin) do
      {:ok, {0xA0, _l, child, _}} -> {:ok, child}
      {:ok, {0x30, _l, child, _}} -> {:ok, child}
      _ -> {:error, :no_token}
    end
  end

  # ── TLV primitives ─────────────────────────────────────────────────────

  defp split_tlv(<<tag, len, rest::binary>>) when len < 0x80 do
    <<content::binary-size(^len), rest::binary>> = rest
    {:ok, {tag, len, content, rest}}
  end

  defp split_tlv(<<tag, 0x81, len, rest::binary>>) do
    <<content::binary-size(^len), rest::binary>> = rest
    {:ok, {tag, len, content, rest}}
  end

  defp split_tlv(<<tag, 0x82, len::16, rest::binary>>) do
    <<content::binary-size(^len), rest::binary>> = rest
    {:ok, {tag, len, content, rest}}
  end

  defp split_tlv(<<tag, 0x83, len::24, rest::binary>>) do
    <<content::binary-size(^len), rest::binary>> = rest
    {:ok, {tag, len, content, rest}}
  end

  defp split_tlv(_), do: :error

  @doc false
  def tlvs(bin), do: read_tlvs(bin, [])

  defp read_tlvs(<<>>, acc), do: Enum.reverse(acc)

  defp read_tlvs(bin, acc) do
    case split_tlv(bin) do
      {:ok, {t, _l, c, rest}} -> read_tlvs(rest, [{t, c} | acc])
      :error -> Enum.reverse(acc)
    end
  end

  defp find(tlvs, tag) when is_list(tlvs) do
    case Enum.find(tlvs, fn {t, _} -> t == tag end) do
      {_t, content} -> content
      nil -> nil
    end
  end

  # ── Token verification ─────────────────────────────────────────────────

  @doc """
  Verify a TimeStampToken over the digest we requested.

  Checks the `messageImprint`, then verifies the CMS signature over the
  `TSTInfo` (bare-content or signed attributes) with the embedded cert.

  Returns `{:ok, ts_info}` or `{:error, reason}`.
  """
  def verify(token_der, expected_digest) when is_binary(token_der) do
    with {:ok, sd_content} <- signed_data_content(token_der),
         {:ok, econtent} <- encapsulated_content(sd_content),
         {:ok, tst_info} <- parse_tst_info(econtent),
         true <-
           tst_info.message_imprint == expected_digest or
             {:error, :message_imprint_mismatch},
         :ok <- verify_cms_signature(econtent, sd_content) do
      {:ok, Map.put(tst_info, :signature_valid, true)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ContentInfo ::= SEQUENCE { contentType, content [0] EXPLICIT SignedData }
  defp signed_data_content(token_der) do
    with {:ok, {0x30, _l, ci_content, ""}} <- split_tlv(token_der),
         entries <- tlvs(ci_content),
         oid when oid != nil <- find(entries, 0x06),
         true <- decode_oid(oid) == @oid_signed_data or {:error, :not_signed_data},
         ctx when ctx not in [nil, ""] <- find(entries, 0xA0),
         {:ok, {0x30, _l2, sd_content, ""}} <- split_tlv(ctx) do
      {:ok, sd_content}
    else
      _ -> {:error, :not_signed_data}
    end
  end

  # Returns the TSTInfo DER (the eContent of the SignedData).
  defp encapsulated_content(sd_content) do
    entries = tlvs(sd_content)

    eci =
      Enum.find(entries, fn
        {0x30, c} -> find(tlvs(c), 0xA0) != nil
        _ -> false
      end)

    case eci do
      {0x30, eci_content} ->
        ctx = find(tlvs(eci_content), 0xA0)

        case split_tlv(ctx || "") do
          {:ok, {0x04, _l, econtent, _}} -> {:ok, econtent}
          _ -> {:error, :no_econtent}
        end

      nil ->
        {:error, :no_encap_content}
    end
  end

  # TSTInfo ::= SEQUENCE { version, policy, messageImprint, serialNumber, genTime, ... }
  defp parse_tst_info(econtent) do
    with {:ok, {0x30, _l, content, ""}} <- split_tlv(econtent) do
      entries = tlvs(content)

      {_, imprint_content} =
        Enum.find(entries, fn {t, _} -> t == 0x30 end) || {0x30, ""}

      imprint = tlvs(imprint_content)

      {:ok,
       %{
         gen_time: find(entries, 0x18),
         message_imprint: find(imprint, 0x04),
         serial_number: unsigned_or_nil(find(entries, 0x02)),
         policy: decode_oid(find(entries, 0x06)),
         digest_algorithm: decode_oid(find(imprint, 0x06))
       }}
    else
      _ -> {:error, :bad_tst_info}
    end
  end

  # ── CMS signature verification ─────────────────────────────────────────

  defp verify_cms_signature(econtent, sd_content) do
    entries = tlvs(sd_content)

    with {:ok, cert_der} <- first_cert(find(entries, 0xA0) || ""),
         {:ok, signer_content} <- first_signer(find(entries, 0x31) || ""),
         {:ok, digest_alg} <- algorithm_oid(signer_digest_algorithm(signer_content)),
         {:ok, sig_alg} <- algorithm_oid(signer_signature_algorithm(signer_content)),
         {:ok, signature} <- signer_signature(signer_content),
         {:ok, signed_payload} <- signed_payload(signer_content, econtent),
         {:ok, key} <- cert_public_key(cert_der),
         true <- do_verify(signed_payload, signature, sig_alg, digest_alg, key) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :tsa_bad_signature}
      _ -> {:error, :tsa_verification_failed}
    end
  end

  defp first_cert(""), do: {:error, :no_signer_cert}

  defp first_cert(cert_set_content) do
    case split_tlv(cert_set_content) do
      {:ok, {0x30, _l, cert, _}} -> {:ok, cert}
      _ -> {:error, :no_signer_cert}
    end
  end

  defp first_signer(""), do: {:error, :no_signer}

  defp first_signer(signer_infos) do
    case split_tlv(signer_infos) do
      {:ok, {0x30, _l, content, _}} -> {:ok, content}
      _ -> {:error, :no_signer}
    end
  end

  # SignerInfo ::= SEQUENCE { version, sid, digestAlg, [signedAttrs], sigAlg, signature }.
  # SEQUENCE #2 in order = digestAlgorithm, SEQUENCE #3 = signatureAlgorithm.
  defp signer_digest_algorithm(signer_content) do
    signer_content |> seq_contents() |> Enum.at(1) || ""
  end

  defp signer_signature_algorithm(signer_content) do
    case signer_content |> seq_contents() do
      [_, _, sig_alg | _] -> sig_alg
      _ -> ""
    end
  end

  defp seq_contents(bin), do: for({0x30, c} <- tlvs(bin), do: c)

  defp signer_signature(signer_content) do
    case Enum.find(tlvs(signer_content), fn {t, _} -> t == 0x04 end) do
      {0x04, sig} -> {:ok, sig}
      nil -> {:error, :no_signature}
    end
  end

  # Signed payload: if signedAttrs [0xA0] present, verify messageDigest matches
  # the content hash and sign over the DER of the attributes; else sign eContent.
  defp signed_payload(signer_content, econtent) do
    elems = tlvs(signer_content)

    case find(elems, 0xA0) do
      attrs when attrs in [nil, ""] ->
        {:ok, econtent}

      attrs ->
        if attribute_message_digest(attrs) == :crypto.hash(:sha256, econtent) do
          {:ok, Cms.encode_tag(0xA0, attrs)}
        else
          {:error, :message_digest_mismatch}
        end
    end
  end

  # Attribute ::= SEQUENCE { attrType OID, attrValues SET OF }. messageDigest
  # is OID 1.2.840.113549.1.9.4.
  @doc false
  def attribute_message_digest(attrs_content) do
    attrs_content
    |> tlvs()
    |> Enum.find_value(fn {0x30, attr} ->
      sub = tlvs(attr)

      if decode_oid(find(sub, 0x06)) == @oid_message_digest do
        valset = find(sub, 0x31) || ""

        case split_tlv(valset) do
          {:ok, {0x04, _l, digest, _}} -> digest
          _ -> nil
        end
      else
        nil
      end
    end)
  end

  # AlgorithmIdentifier ::= SEQUENCE { algorithm OID, ... }
  defp algorithm_oid(""), do: {:error, :no_algorithm}

  defp algorithm_oid(alg_seq) do
    case tlvs(alg_seq) do
      [{0x06, oid} | _] -> {:ok, decode_oid(oid)}
      _ -> {:error, :no_algorithm}
    end
  end

  defp cert_public_key(cert_der) do
    decoded = :public_key.pkix_decode_cert(cert_der, :plain)
    tbs = elem(decoded, 1)
    {:ok, :public_key.der_decode(:SubjectPublicKeyInfo, elem(tbs, 7))}
  rescue
    _ -> {:error, :bad_cert}
  end

  defp do_verify(payload, signature, sig_alg, digest_alg, key) do
    hash_type = hash_for(digest_alg)
    key_type = key_for(sig_alg)

    if hash_type && key_type do
      :public_key.verify(payload, hash_type, signature, key)
    else
      false
    end
  rescue
    _ -> false
  end

  defp hash_for({2, 16, 840, 1, 101, 3, 4, 2, 1}), do: :sha256
  defp hash_for(_), do: nil

  defp key_for({1, 2, 840, 113_549, 1, 1, 11}), do: :rsa
  defp key_for({1, 2, 840, 100_045, 4, 3, 2}), do: :ecdsa
  defp key_for(_), do: nil

  # ── OID decode ─────────────────────────────────────────────────────────

  def unsigned_or_nil(nil), do: nil
  def unsigned_or_nil(bin), do: :binary.decode_unsigned(bin)

  @doc false
  def decode_oid(nil), do: nil

  def decode_oid(<<first, rest::binary>>) do
    a = div(first, 40)
    b = rem(first, 40)
    {components, _} = decode_base128_stream(rest, [])
    List.to_tuple([a, b | Enum.reverse(components)])
  end

  def decode_oid(_), do: nil

  defp decode_base128_stream(<<>>, acc), do: {acc, <<>>}

  defp decode_base128_stream(bin, acc) do
    {value, rest} = decode_base128(bin, 0)
    decode_base128_stream(rest, [value | acc])
  end

  defp decode_base128(<<byte, rest::binary>>, acc) when byte < 0x80 do
    {acc * 128 + byte, rest}
  end

  defp decode_base128(<<byte, rest::binary>>, acc) do
    decode_base128(rest, acc * 128 + (byte - 128))
  end
end
