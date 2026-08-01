defmodule Quire.Pades.Cms do
  import Bitwise, only: [|||: 2, &&&: 2, >>>: 2]

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
  @oid_signing_time {1, 2, 840, 113_549, 1, 9, 5}
  @oid_signature_time_stamp_token {1, 2, 840, 113_549, 1, 9, 16, 2, 14}

  @doc """
  Build a PAdES **BES / EPES** detached SignedData with signed attributes
  (contentType, messageDigest, and optional signingTime) and optional unsigned
  attributes (an RFC 3161 `signatureTimeStampToken` for B-T).

  ## Parameters
    - `content_hash`: SHA-256 of the PDF byte range(s)
    - `signer_cert_der`: DER X.509 certificate of the signer
    - `sign_fun`: `fn(digest) -> {:ok, signature_binary} end` — signs the digest
      with the signer's private key (RSA or ECDSA). The signature is computed
      over the DER encoding of the signed attributes, per CMS/PAdES-BES.
    - `opts`:
        - `:signature_algorithm` (`:rsa` | `:ecdsa`, default `:rsa`)
        - `:signing_time` (DateTime, default now)
        - `:timestamp_token` (binary DER TimeStampToken, optional — when
          present it is attached as the `signatureTimeStampToken` unsigned
          attribute → B-T profile)

  Returns `{:ok, der_binary}` or `{:error, term()}`.
  """
  def build_bes_signed_data(content_hash, signer_cert_der, sign_fun, opts \\ []) do
    sig_alg = Keyword.get(opts, :signature_algorithm, :rsa)
    signing_time = Keyword.get(opts, :signing_time, DateTime.utc_now())
    token = Keyword.get(opts, :timestamp_token)

    with {:ok, {issuer, serial}} <- extract_issuer_and_serial(signer_cert_der) do
      signed_attrs = build_signed_attrs(content_hash, signing_time)
      signed_attrs_der = encode_tag(0xA0, signed_attrs)
      digest = :crypto.hash(:sha256, signed_attrs_der)

      with {:ok, signature} <- sign_fun.(digest) do
        unsigned_attrs = if token, do: build_unsigned_attrs(token), else: ""
        cms = build_bes_cms(content_hash, signature, signer_cert_der, issuer, serial, sig_alg, signed_attrs_der, unsigned_attrs)
        {:ok, cms}
      end
    end
  end

  # SignedAttributes ::= [0] IMPLICIT SET OF Attribute (POST-sorted by DER).
  defp build_signed_attrs(content_hash, signing_time) do
    attrs =
      [
        encode_attribute(@oid_content_type, encode_oid(@oid_data)),
        encode_attribute(@oid_message_digest, encode_octet_string(content_hash)),
        encode_attribute(@oid_signing_time, encode_utc_time(signing_time))
      ]
      |> IO.iodata_to_binary()

    encode_set_der(attrs)
  end

  # unsignedAttrs ::= [1] IMPLICIT SET OF Attribute
  defp build_unsigned_attrs(token) do
    encode_tag(
      0xA1,
      encode_set_der(encode_attribute(@oid_signature_time_stamp_token, encode_octet_string(token)))
    )
  end

  defp build_bes_cms(_content_hash, signature, cert_der, issuer, serial, sig_alg, signed_attrs_der, unsigned_attrs) do
    digest_alg_oid = @oid_sha256
    signature_alg_oid = signature_oid(sig_alg)
    digest_alg_id = encode_algorithm_id(digest_alg_oid)
    sig_alg_id = encode_algorithm_id(signature_alg_oid)

    signer_id = encode_sequence([issuer, encode_integer(serial)])

    signer_info_der =
      encode_sequence(
        Enum.reject(
          [
            encode_integer(1),           # version
            signer_id,                    # sid
            digest_alg_id,                # digestAlgorithm
            nonempty(signed_attrs_der),   # signedAttrs [0]
            sig_alg_id,                   # signatureAlgorithm
            encode_octet_string(signature),
            nonempty(unsigned_attrs)      # unsignedAttrs [1]
          ],
          &is_nil/1
        )
      )

    encap_content_info = encode_sequence([encode_oid(@oid_data)])
    cert_set_tagged = encode_tag(0xA0, encode_set([cert_der]))

    signed_data_der =
      encode_sequence([
        encode_integer(3),                # version — BES uses CMS version 3
        encode_set([digest_alg_id]),
        encap_content_info,
        cert_set_tagged,
        encode_set([signer_info_der])
      ])

    encode_sequence([
      encode_oid(@oid_signed_data),
      encode_tag(0xA0, signed_data_der)
    ])
  end

  defp nonempty(""), do: nil
  defp nonempty(bin) when is_binary(bin), do: bin

  @doc false
  def encode_attribute(oid, value) do
    encode_sequence([encode_oid(oid), encode_set([value])])
  end

  @doc false
  def encode_utc_time(%DateTime{} = dt) do
    # DER UTCTime ::= YYMMDDHHMMSSZ (UTC, no seconds fraction)
    dt = DateTime.truncate(dt, :second) |> DateTime.shift_zone!("Etc/UTC")

    <<year::binary-size(2), _rest::binary>> = String.pad_leading(Integer.to_string(dt.year), 4, "0")

    s =
      year <> "#{pad(dt.month)}#{pad(dt.day)}#{pad(dt.hour)}#{pad(dt.minute)}#{pad(dt.second)}Z"

    encode_tag(0x17, s)
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: Integer.to_string(n)

  defp encode_set_der(attrs_bin) do
    # SET OF requires canonical order — sort the embedded Attribute elements.
    encode_set(parse_elements(attrs_bin, []))
  end

  # Re-serialize the SET OF Attribute with DER canonical ordering by re-reading
  # each Attribute TLV from the pre-encoded stream.
  defp parse_elements(<<>>, acc), do: Enum.reverse(acc)

  defp parse_elements(bin, acc) do
    {{tag, content}, rest} = decode_tlv(bin)
    parse_elements(rest, [encode_tag(tag, content) | acc])
  end

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

  defp build_cms(_content_hash, signature_bytes, cert_der, issuer, serial, sig_alg) do
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
    inverted = for(<<b::8 <- unsigned>>, do: <<Bitwise.bxor(b, 0xFF)>>) |> IO.iodata_to_binary()
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
  def encode_boolean(true), do: encode_tag(0x01, <<0xFF>>)
  def encode_boolean(false), do: encode_tag(0x01, <<0x00>>)

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
    <<value::binary-size(^len), remainder::binary>> = rest
    {{tag, value}, remainder}
  end

  def decode_tlv(<<tag, 0x81, len::8, rest::binary>>) do
    <<value::binary-size(^len), remainder::binary>> = rest
    {{tag, value}, remainder}
  end

  def decode_tlv(<<tag, 0x82, len::16, rest::binary>>) do
    <<value::binary-size(^len), remainder::binary>> = rest
    {{tag, value}, remainder}
  end
end
