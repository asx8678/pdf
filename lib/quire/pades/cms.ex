defmodule Quire.Pades.Cms do
  import Bitwise, only: [|||: 2, &&&: 2, >>>: 2, "^^^": 2]

  @moduledoc """
  Builds detached CMS (Cryptographic Message Syntax) SignedData structures
  conforming to RFC 5652 for PAdES digital signatures (ETSI EN 319 142).

  Pure Elixir — builds DER manually using ASN.1 TLV primitives,
  backed by OTP `:public_key` for certificate parsing and `:crypto` for hashing.
  """

  # ── OID constants ──────────────────────────────────────────────────
  @oid_sha256 {2, 16, 840, 1, 101, 3, 4, 2, 1}
  @oid_sha256_with_rsa {1, 2, 840, 113_549, 1, 1, 11}
  @oid_ecdsa_with_sha256 {1, 2, 840, 100_045, 4, 3, 2}
  @oid_data {1, 2, 840, 113_549, 1, 7, 1}
  @oid_signed_data {1, 2, 840, 113_549, 1, 7, 2}
  @oid_content_type {1, 2, 840, 113_549, 1, 9, 3}
  @oid_message_digest {1, 2, 840, 113_549, 1, 9, 4}

  @doc """
  Build a detached CMS SignedData suitable for embedding in a PDF signature field.

  ## Parameters
    - `content_hash`: SHA-256 hash of the PDF byte range(s) to sign
    - `signature_bytes`: raw RSA or ECDSA signature of the hash
    - `signer_cert_der`: DER-encoded X.509 certificate of the signer
    - `opts`: keyword options — `:signature_algorithm` (`:rsa` or `:ecdsa`, default `:rsa`)

  Returns `{:ok, der_binary}` or `{:error, reason}`.
  """
  @spec build_signed_data(binary(), binary(), binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def build_signed_data(content_hash, signature_bytes, signer_cert_der, opts \\ []) do
    sig_alg = Keyword.get(opts, :signature_algorithm, :rsa)

    with {:ok, {issuer, serial}} <- extract_issuer_and_serial(signer_cert_der) do
      cms_der = build_cms(content_hash, signature_bytes, signer_cert_der, issuer, serial, sig_alg)
      {:ok, cms_der}
    end
  end

  @doc """
  Compute the SHA-256 hash of concatenated PDF byte ranges.

  The byte range is specified as `[start, length, start, length, ...]`.
  """
  @spec hash_byte_range(binary(), [non_neg_integer()]) :: binary()
  def hash_byte_range(pdf_binary, byte_range) do
    parts =
      byte_range
      |> Enum.chunk_every(2)
      |> Enum.map(fn [offset, length] ->
        binary_part(pdf_binary, offset, length)
      end)

    :crypto.hash(:sha256, Enum.join(parts))
  end

  # ── CMS DER construction ───────────────────────────────────────────

  defp build_cms(content_hash, signature_bytes, cert_der, issuer, serial, sig_alg) do
    digest_alg_oid = @oid_sha256
    signature_alg_oid = signature_oid(sig_alg)

    # ── AlgorithmIdentifiers ──
    digest_alg_id = encode_algorithm_id(digest_alg_oid)
    sig_alg_id = encode_algorithm_id(signature_alg_oid)

    # ── SignerIdentifier: CHOICE issuerAndSerialNumber (default, no tag) ──
    # IssuerAndSerialNumber ::= SEQUENCE { issuer Name, serial INTEGER }
    signer_id = encode_sequence([issuer, encode_integer(serial)])

    # ── SignerInfo (no signedAttrs for basic detached signature) ──
    signer_info_der =
      encode_sequence([
        # version
        encode_integer(1),
        # sid
        signer_id,
        # digestAlgorithm
        digest_alg_id,
        # signatureAlgorithm
        sig_alg_id,
        # signature
        encode_octet_string(signature_bytes)
      ])

    # ── EncapsulatedContentInfo (detached) ──
    encap_content_info = encode_sequence([encode_oid(@oid_data)])

    # ── CertificateSet [0] IMPLICIT ──
    cert_set_tagged = encode_tag(0xA0, encode_set([cert_der]))

    # ── SignedData ──
    signed_data_der =
      encode_sequence([
        # version
        encode_integer(1),
        # digestAlgorithms
        encode_set([digest_alg_id]),
        # encapContentInfo
        encap_content_info,
        # certificates [0]
        cert_set_tagged,
        # signerInfos
        encode_set([signer_info_der])
      ])

    # ── Outer ContentInfo ──
    encode_sequence([
      encode_oid(@oid_signed_data),
      encode_tag(0xA0, signed_data_der)
    ])
  end

  defp signature_oid(:rsa), do: @oid_sha256_with_rsa
  defp signature_oid(:ecdsa), do: @oid_ecdsa_with_sha256

  defp build_attribute(oid, values_der) do
    encode_sequence([encode_oid(oid), values_der])
  end

  defp encode_algorithm_id(oid) do
    encode_sequence([encode_oid(oid), encode_null()])
  end

  # ── Certificate parsing ────────────────────────────────────────────

  # Extract {IssuerName DER, SerialNumber} from DER X.509 certificate.
  #
  # OTPCertificate = {:"OTPCertificate", tbsCert, signAlg, signature}
  # tbsCert components:
  #   [0] version (optional, default v1)
  #   [1] serialNumber
  #   [2] signature (AlgorithmIdentifier)
  #   [3] issuer (Name)
  #   [4] validity
  #   [5] subject
  #   [6] subjectPublicKeyInfo
  defp extract_issuer_and_serial(cert_der) do
    decoded = :public_key.pkix_decode_cert(cert_der, :plain)
    tbs_cert = elem(decoded, 1)
    serial = elem(tbs_cert, 2)
    issuer_tuple = elem(tbs_cert, 4)
    # Re-encode the Name to DER using OTP
    issuer_der = :public_key.der_encode(:Name, issuer_tuple)
    {:ok, {issuer_der, serial}}
  rescue
    e -> {:error, {:cert_parse_error, Exception.message(e)}}
  end

  # ── ASN.1 DER encoding primitives ─────────────────────────────────

  @doc false
  def encode_oid(tuple) when is_tuple(tuple) do
    [first, second | rest] = Tuple.to_list(tuple)
    head = 40 * first + second
    body = encode_oid_components(rest)
    octets = <<head, body::binary>>
    encode_tag(0x06, octets)
  end

  defp encode_oid_components([]), do: <<>>

  defp encode_oid_components([v | rest]) do
    encoded = encode_base128(v)
    <<encoded::binary, encode_oid_components(rest)::binary>>
  end

  # Encode a non-negative integer in base-128 big-endian DER.
  # All bytes except the last have the high bit (0x80) set.
  defp encode_base128(0), do: <<0>>

  defp encode_base128(v) do
    # Collect 7-bit groups, MSB first
    groups = collect_groups(v, [])
    len = length(groups)

    groups
    |> Enum.with_index()
    |> Enum.map(fn {g, i} ->
      if i < len - 1, do: 0x80 ||| g, else: g
    end)
    |> IO.iodata_to_binary()
  end

  defp collect_groups(0, acc), do: acc

  defp collect_groups(v, acc) do
    collect_groups(v >>> 7, [v &&& 0x7F | acc])
  end

  @doc false
  def encode_integer(value) when value >= 0 do
    bin = encode_unsigned(value)
    bin = if bin == <<>>, do: <<0>>, else: bin
    # Add leading zero if high bit set
    bin = if binary_part(bin, 0, 1) >= <<0x80>>, do: <<0x00, bin::binary>>, else: bin
    encode_tag(0x02, bin)
  end

  def encode_integer(value) when value < 0 do
    # Two's complement: for -x, encode ~(x-1)
    unsigned = encode_unsigned(-value - 1)
    # Bitwise NOT of each byte
    inverted = for(<<b::8 <- unsigned>>, do: <<b ^^^ 0xFF>>) |> IO.iodata_to_binary()
    encode_tag(0x02, inverted)
  end

  defp encode_unsigned(0), do: <<>>

  defp encode_unsigned(value) do
    encode_unsigned(value, [])
  end

  defp encode_unsigned(0, acc), do: IO.iodata_to_binary(acc)

  defp encode_unsigned(value, acc) do
    encode_unsigned(value >>> 8, [<<value &&& 0xFF>> | acc])
  end

  @doc false
  def encode_octet_string(bin), do: encode_tag(0x04, bin)

  @doc false
  def encode_null, do: encode_tag(0x05, <<>>)

  @doc false
  def encode_sequence(elements) when is_list(elements) do
    encode_tag(0x30, IO.iodata_to_binary(elements))
  end

  @doc false
  def encode_set(elements) when is_list(elements) do
    # SET OF: DER requires canonical order
    sorted = Enum.sort(elements)
    encode_tag(0x31, IO.iodata_to_binary(sorted))
  end

  @doc false
  def encode_tag(tag, content) when is_integer(tag) and is_binary(content) do
    len = byte_size(content)

    cond do
      len < 0x80 ->
        <<tag, len::8, content::binary>>

      len < 0x100 ->
        <<tag, 0x81, len::8, content::binary>>

      len < 0x10000 ->
        <<tag, 0x82, len::16, content::binary>>

      len < 0x1_000000 ->
        <<tag, 0x83, len::24, content::binary>>

      true ->
        len_bytes = encode_unsigned(len)
        <<tag, 0x80 ||| byte_size(len_bytes), len_bytes::binary, content::binary>>
    end
  end

  # ── DER decoding helpers (for testing / verification) ──────────────

  @doc false
  def decode_tlv(<<tag, len::8, rest::binary>>) when len < 0x80 do
    <<value::binary-size(len), remainder::binary>> = rest
    {{tag, value}, remainder}
  end

  def decode_tlv(<<tag, 0x81, len::8, rest::binary>>) do
    <<value::binary-size(len), remainder::binary>> = rest
    {{tag, value}, remainder}
  end

  def decode_tlv(<<tag, 0x82, len::16, rest::binary>>) do
    <<value::binary-size(len), remainder::binary>> = rest
    {{tag, value}, remainder}
  end
end
