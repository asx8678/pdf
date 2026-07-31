defmodule Quire.Pades.Pkcs12 do
  @moduledoc """
  Parses PKCS#12 keystores (RFC 7292) to extract private keys and certificates.
  Pure Elixir over OTP `:public_key` and `:crypto`.
  """

  @type private_key :: %{algorithm: :rsa | :ecdsa, key_der: binary(), key_id: binary() | nil}
  @type certificate :: %{der: binary(), key_id: binary() | nil}

  @oid_data {1, 2, 840, 113_549, 1, 7, 1}
  @oid_encrypted_data {1, 2, 840, 113_549, 1, 7, 6}
  @oid_key_bag {1, 2, 840, 113_549, 1, 12, 10, 1, 1}
  @oid_pkcs8_shrouded_key_bag {1, 2, 840, 113_549, 1, 12, 10, 1, 2}
  @oid_cert_bag {1, 2, 840, 113_549, 1, 12, 10, 1, 3}
  @oid_pbe_sha1_3des {1, 2, 840, 113_549, 1, 12, 1, 3}
  @oid_x509_certificate {1, 2, 840, 113_549, 1, 9, 22, 1}
  @oid_rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}
  @oid_ec_public_key {1, 2, 840, 10_045, 2, 1}

  @doc """
  Parse a PKCS#12 (`PFX`) binary and return embedded private keys and certificates.
  """
  @spec parse(binary(), String.t()) :: {:ok, [private_key()], [certificate()]} | {:error, term()}
  def parse(pfx_binary, password) when is_binary(pfx_binary) and is_binary(password) do
    with {:ok, keys, certs} <- decode_pfx(pfx_binary, password) do
      {:ok, keys, certs}
    end
  end

  # ── PFX ──────────────────────────────────────────────────────────────

  defp decode_pfx(<<0x30, len::8, rest::binary>>, pw) when len < 128,
    do: decode_pfx_cont(rest, len, pw)

  defp decode_pfx(<<0x30, 0x81, len::8, rest::binary>>, pw),
    do: decode_pfx_cont(rest, len, pw)

  defp decode_pfx(<<0x30, 0x82, len::16, rest::binary>>, pw),
    do: decode_pfx_cont(rest, len, pw)

  defp decode_pfx(<<0x30, 0x83, len::24, rest::binary>>, pw),
    do: decode_pfx_cont(rest, len, pw)

  defp decode_pfx(bin, _pw), do: {:error, {:bad_pfx, byte_size(bin)}}

  defp decode_pfx_cont(rest, len, pw) do
    <<content::binary-size(^len), _::binary>> = rest
    parse_pfx_content(content, pw)
  end

  defp parse_pfx_content(content, pw) do
    [{0x02, ver}, {0x30, auth_safe_tlv} | _] = read_elems(content)
    if ver != <<3>>, do: {:error, {:bad_version, ver}}

    {ci_oid, ci_content} = parse_content_info(auth_safe_tlv)
    process_auth_safe(ci_oid, ci_content, pw)
  end

  # ── ContentInfo ──────────────────────────────────────────────────────

  # ContentInfo ::= SEQUENCE { contentType OID, content [0] EXPLICIT ANY }
  # Input: binary content of the SEQUENCE (tag+len already stripped)
  defp parse_content_info(bin) do
    [{0x06, oid_raw}, {_, ctx_val} | _] = read_elems(bin)
    {decode_oid(oid_raw), ctx_val}
  end

  # ── AuthSafe ─────────────────────────────────────────────────────────

  defp process_auth_safe(@oid_data, content, pw) do
    # content is [0] EXPLICIT inner value = OCTET STRING containing AuthenticatedSafe
    case unwrap_octet_string(content) do
      {:ok, octets} -> auth_safe_result(parse_auth_safe(octets, pw))
      e -> e
    end
  end

  defp process_auth_safe(@oid_encrypted_data, content, pw) do
    # content is [0] EXPLICIT inner value = EncryptedData SEQUENCE
    case decrypt_encrypted_data(content, pw) do
      {:ok, plain} -> auth_safe_result(parse_auth_safe(plain, pw))
      e -> e
    end
  end

  defp auth_safe_result({keys, certs}), do: {:ok, keys, certs}
  defp auth_safe_result(other), do: other

  # ── AuthenticatedSafe ────────────────────────────────────────────────

  # AuthenticatedSafe ::= SEQUENCE OF ContentInfo
  defp parse_auth_safe(bin, pw) do
    read_seq(bin)
    |> Enum.reduce({[], []}, fn {_, val}, {ks, cs} ->
      process_auth_ci(val, pw, ks, cs)
    end)
  end

  defp process_auth_ci(bin, pw, ks, cs) do
    {oid, content} = parse_content_info(bin)

    case extract_safe_contents_for_oid(oid, content, pw) do
      {new_ks, new_cs} -> {new_ks ++ ks, new_cs ++ cs}
      other -> other
    end
  end

  defp extract_safe_contents_for_oid(@oid_data, content, pw) do
    # content is [0] EXPLICIT inner value = OCTET STRING containing SafeContents
    case unwrap_octet_string(content) do
      {:ok, octets} -> extract_safe_contents(octets, pw)
      _ -> {[], []}
    end
  end

  defp extract_safe_contents_for_oid(@oid_encrypted_data, content, pw) do
    case decrypt_encrypted_data(content, pw) do
      {:ok, plain} -> extract_safe_contents(plain, pw)
      _ -> {[], []}
    end
  end

  defp extract_safe_contents_for_oid(_oid, _content, _pw), do: {[], []}

  # ── EncryptedData ────────────────────────────────────────────────────

  # EncryptedData ::= SEQUENCE { version INTEGER, encryptedContentInfo ECI }
  # Input: [0] EXPLICIT content = EncryptedData TLV (starts with 0x30)
  defp decrypt_encrypted_data(enc_content, pw) do
    [{0x02, _ver}, {0x30, eci} | _] = read_seq(enc_content)
    [{0x06, _ct}, {0x30, alg_bin}, {_tag, enc_data} | _] = read_elems(eci)
    {algo_oid, params} = parse_enc_alg(alg_bin)

    case pbe_decrypt(algo_oid, pw, params, enc_data) do
      {:ok, plain} -> {:ok, strip_pkcs7_pad(plain)}
      e -> e
    end
  end

  # ── Encryption Algorithm Identifier ──────────────────────────────────

  # Input: AlgorithmIdentifier SEQUENCE content (after stripping 0x30 tag)
  defp parse_enc_alg(bin) do
    [{0x06, oid_raw}, params_elem | _] = read_elems(bin)
    {decode_oid(oid_raw), elem_raw(params_elem)}
  end

  # ── PBE ──────────────────────────────────────────────────────────────

  defp pbe_decrypt(@oid_pbe_sha1_3des, pw, params_bin, data) do
    {salt, iter} = parse_pbe_params(params_bin)
    key = pkcs12_kdf(pw, salt, iter, 24, :sha, 1)
    iv = pkcs12_kdf(pw, salt, iter, 8, :sha, 2)
    {:ok, :crypto.crypto_one_time(:des_ede3_cbc, key, iv, data, false)}
  end

  defp pbe_decrypt(oid, _pw, _params, _data), do: {:error, {:unsupported_pbe, oid}}

  # Strip PKCS#7 padding from decrypted block cipher output
  defp strip_pkcs7_pad(data) when byte_size(data) > 0 do
    pad_byte = :binary.at(data, byte_size(data) - 1)

    if pad_byte > 0 and pad_byte <= 8 do
      :binary.part(data, 0, byte_size(data) - pad_byte)
    else
      data
    end
  end

  # PBEParameter ::= SEQUENCE { salt OCTET STRING, iterationCount INTEGER }
  defp parse_pbe_params(bin) do
    [{0x04, salt}, {0x02, iter_raw} | _] = read_elems(bin)
    {salt, decode_int(iter_raw)}
  end

  # PKCS#12 Key Derivation (RFC 7292 §B)
  # PKCS#12 Key Derivation (RFC 7292 §B, matching OpenSSL PKCS12_key_gen_uni)
  defp pkcs12_kdf(pw, salt, iter, need, hash, id) do
    hl = :crypto.hash_info(hash).size
    v = :crypto.hash_info(hash).block_size
    pw16 = pkcs12_pw_bytes(pw)
    pw16_len = byte_size(pw16)
    salt_len = byte_size(salt)

    # D = id byte repeated to fill block size
    d = :binary.copy(<<id>>, v)

    # Slen and Plen are multiples of v, with salt/password REPEATED (not zero-padded)
    slen = v * ceil(salt_len / v)
    plen = if pw16_len > 0, do: v * ceil(pw16_len / v), else: 0
    ilen = slen + plen

    # Build I by repeating salt and password to fill their respective lengths
    i_block =
      IO.iodata_to_binary([
        repeat_to_len(salt, slen),
        repeat_to_len(pw16, plen)
      ])

    iterate_kdf(d, i_block, ilen, need, iter, hash, v, hl)
  end

  # Repeat `data` to reach `len` bytes total
  defp repeat_to_len(_data, 0), do: <<>>

  defp repeat_to_len(data, len) do
    dlen = byte_size(data)
    reps = div(len, dlen)
    rem = rem(len, dlen)
    :binary.copy(data, reps) <> binary_part(data, 0, rem)
  end

  defp iterate_kdf(_d, _i_block, _ilen, need, _iter, _hash, _v, _hl) when need <= 0, do: <<>>

  defp iterate_kdf(d, i_block, ilen, need, iter, hash, v, hl) do
    ai = :crypto.hash(hash, d <> i_block)
    ai = if iter > 1, do: Enum.reduce(2..iter, ai, fn _, h -> :crypto.hash(hash, h) end), else: ai

    taken = min(need, hl)
    result = binary_part(ai, 0, taken)
    remaining = need - taken

    if remaining > 0 do
      # Build B = Ai repeated to v bytes
      b = repeat_to_len(ai, v)
      # B+1 as big integer
      b_plus_1 = :binary.decode_unsigned(b) + 1
      # Update each v-byte block of I: I_j = I_j + B + 1 (mod 2^(v*8))
      num_blocks = div(ilen, v)

      new_blocks =
        for j <- 0..(num_blocks - 1) do
          offset = j * v
          block = binary_part(i_block, offset, v)
          sum = :binary.decode_unsigned(block) + b_plus_1
          sum_bin = :binary.encode_unsigned(sum, :big)
          # Trim to v bytes (take rightmost v bytes)
          sbs = byte_size(sum_bin)

          if sbs > v,
            do: binary_part(sum_bin, sbs - v, v),
            else: <<0::size(v - sbs)-unit(8)>> <> sum_bin
        end

      new_i_block = IO.iodata_to_binary(new_blocks)
      result <> iterate_kdf(d, new_i_block, ilen, remaining, iter, hash, v, hl)
    else
      result
    end
  end

  # PKCS#12 BMPString encoding: UTF-16BE with 2-byte null terminator
  defp pkcs12_pw_bytes(pw) do
    for(<<c <- pw>>, into: <<>>, do: <<0, c>>) <> <<0, 0>>
  end

  # ── SafeContents ────────────────────────────────────────────────────

  # SafeContents ::= SEQUENCE OF SafeBag
  defp extract_safe_contents(bin, pw) do
    case read_seq(bin) do
      bags when is_list(bags) ->
        Enum.reduce(bags, {[], []}, fn {_, bag_tlv}, {ks, cs} ->
          bag = read_elems(bag_tlv)
          process_bag(bag, pw, ks, cs)
        end)

      _ ->
        {[], []}
    end
  rescue
    _ -> {[], []}
  end

  defp process_bag([{0x06, oid_raw}, {_, val} | _], pw, ks, cs) do
    case decode_oid(oid_raw) do
      @oid_key_bag -> handle_key_bag(val, ks, cs)
      @oid_pkcs8_shrouded_key_bag -> handle_shrouded_bag(val, pw, ks, cs)
      @oid_cert_bag -> handle_cert_bag(val, ks, cs)
      _ -> {ks, cs}
    end
  end

  defp process_bag(_, _pw, ks, cs), do: {ks, cs}

  # ── Key / Shrouded / Cert bag handlers ───────────────────────────────

  # bag_value is [0] EXPLICIT content containing PKCS#8 PrivateKeyInfo
  defp handle_key_bag(val, ks, cs) do
    algo = key_algo_from_pkcs8(val)
    {[%{algorithm: algo, key_der: val, key_id: nil} | ks], cs}
  end

  defp handle_shrouded_bag(val, pw, ks, cs) do
    [{0x30, alg_content}, {0x04, enc_key} | _] = read_seq(val)
    {algo_oid, params} = parse_enc_alg(alg_content)

    case pbe_decrypt(algo_oid, pw, params, enc_key) do
      {:ok, plain_key} ->
        plain_key = strip_pkcs7_pad(plain_key)
        algo = key_algo_from_pkcs8(plain_key)
        {[%{algorithm: algo, key_der: plain_key, key_id: nil} | ks], cs}

      _ ->
        {ks, cs}
    end
  end

  defp handle_cert_bag(val, ks, cs) do
    items = read_seq(val)
    [{0x06, ct_raw}, {0xA0, cv_content} | _] = items

    if decode_oid(ct_raw) == @oid_x509_certificate do
      # x509Certificate bag value is OCTET STRING wrapping DER certificate
      cert_der =
        case unwrap_octet_string(cv_content) do
          {:ok, der} -> der
          _ -> cv_content
        end

      {ks, [%{der: cert_der, key_id: nil} | cs]}
    else
      {ks, cs}
    end
  end

  # Extract key algorithm from PKCS#8 PrivateKeyInfo
  defp key_algo_from_pkcs8(der) do
    [{0x02, _ver}, {0x30, alg_bin} | _] = read_seq(der)
    [{0x06, oid_raw} | _] = read_elems(alg_bin)

    case decode_oid(oid_raw) do
      @oid_rsa_encryption -> :rsa
      @oid_ec_public_key -> :ecdsa
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  # ── OID helpers ──────────────────────────────────────────────────────

  defp decode_oid(<<oid_bin::binary>>) do
    decode_oid_bytes(oid_bin)
  end

  # Manual OID DER decoding (no :public_key type for OID)
  defp decode_oid_bytes(<<first, rest::binary>>) do
    a = div(first, 40)
    b = rem(first, 40)
    {components, _} = decode_base128_stream(rest, [])
    List.to_tuple([a, b | Enum.reverse(components)])
  end

  defp decode_base128_stream(<<>>, acc), do: {acc, <<>>}

  defp decode_base128_stream(bin, acc) do
    {val, rest} = decode_base128(bin, 0)
    decode_base128_stream(rest, [val | acc])
  end

  defp decode_base128(<<byte, rest::binary>>, acc) when byte < 0x80,
    do: {acc * 128 + byte, rest}

  defp decode_base128(<<byte, rest::binary>>, acc),
    do: decode_base128(rest, acc * 128 + (byte - 128))

  # ── Element helpers ──────────────────────────────────────────────────

  defp elem_raw({_tag, val}), do: val
  defp elem_raw(bin) when is_binary(bin), do: bin

  defp decode_int(<<n::binary>>), do: :binary.decode_unsigned(n)

  # Strip OCTET STRING (0x04) wrapper
  defp unwrap_octet_string(<<0x04, len::8, rest::binary>>) when len < 128,
    do: {:ok, binary_part(rest, 0, len)}

  defp unwrap_octet_string(<<0x04, 0x81, len::8, rest::binary>>),
    do: {:ok, binary_part(rest, 0, len)}

  defp unwrap_octet_string(<<0x04, 0x82, len::16, rest::binary>>),
    do: {:ok, binary_part(rest, 0, len)}

  defp unwrap_octet_string(<<0x04, 0x83, len::24, rest::binary>>),
    do: {:ok, binary_part(rest, 0, len)}

  defp unwrap_octet_string(_), do: {:error, :bad_octet_string}

  # ── DER element reader ───────────────────────────────────────────────

  # Read all TLV elements from a binary. Binary is content bytes
  # (outer tag+length already stripped). Returns [{tag, value}, ...].
  defp read_elems(<<>>), do: []

  defp read_elems(bin) do
    read_elems(bin, [])
  end

  defp read_elems(<<>>, acc), do: Enum.reverse(acc)

  defp read_elems(bin, acc) do
    case parse_tlv(bin) do
      {{tag, val}, rest} -> read_elems(rest, [{tag, val} | acc])
      :error -> Enum.reverse(acc)
    end
  end

  defp read_seq(bin) do
    [{0x30, inner} | _] = read_elems(bin)
    read_elems(inner)
  end

  defp parse_tlv(<<tag, len::8, rest::binary>>) when len < 128,
    do: {{tag, binary_part(rest, 0, len)}, binary_part(rest, len, byte_size(rest) - len)}

  defp parse_tlv(<<tag, 0x81, len::8, rest::binary>>),
    do: {{tag, binary_part(rest, 0, len)}, binary_part(rest, len, byte_size(rest) - len)}

  defp parse_tlv(<<tag, 0x82, len::16, rest::binary>>),
    do: {{tag, binary_part(rest, 0, len)}, binary_part(rest, len, byte_size(rest) - len)}

  defp parse_tlv(<<tag, 0x83, len::24, rest::binary>>),
    do: {{tag, binary_part(rest, 0, len)}, binary_part(rest, len, byte_size(rest) - len)}

  defp parse_tlv(_), do: :error
end
