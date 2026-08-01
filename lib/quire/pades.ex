defmodule Quire.Pades do
  @moduledoc """
  PAdES signing and validation (§7.2, §11).

  ## Signing flow

      Quire.Pades.sign(pdf_bytes, signer, opts)

  `signer` is a map with:
    - `:certificate_der` — DER X.509 certificate binary (required)
    - `:private_key_der` — DER PKCS#8 private key binary (required)
    - `:algorithm` — `:rsa` or `:ecdsa` (auto-detected if omitted)

  ## Levels

    - `:b_b` — BES/EPES: CMS detached signature with signed attributes
      (contentType, messageDigest, signingTime).
    - `:b_t` — B-B + RFC 3161 TimeStampToken as unsigned attribute,
      obtained from the configured TSA via `Pades.Tsa`.

  ## Verification

  `verify/1` parses every signature dictionary in the PDF, validates
  the CMS against the embedded certificate, checks timestamp tokens,
  and reports byte-range integrity.  Returns a list of result maps
  with `:valid`, `:signer`, `:timestamp` and optional `:warnings`.

  ## Architecture

  Uses `Quire.Pdf` for PDF structure writes (signature dictionary,
  byte-range placeholders, incremental save).  CMS construction is
  handled by `Pades.Cms`; timestamping by `Pades.Tsa`; keystore
  parsing by `Pades.Pkcs12`.
  """

  alias Quire.Pades.{Cms, Tsa, Pkcs12, Validation}

  @type signer :: %{
          certificate_der: binary(),
          private_key_der: binary(),
          algorithm: :rsa | :ecdsa,
          passphrase: String.t() | nil
        }

  @type sign_opts :: [
          pades_level: :b_b | :b_t,
          field_name: String.t(),
          field_rect: [number(), ...],
          page_index: non_neg_integer(),
          reason: String.t(),
          location: String.t(),
          contact_info: String.t(),
          tsa_url: String.t(),
          appearance_png: binary() | nil,
          certificate_der: binary(),
          private_key_der: binary(),
          algorithm: :rsa | :ecdsa
        ]

  @type signature_result :: %{
          signed_bytes: binary(),
          pades_level: :b_b | :b_t,
          field_name: String.t(),
          signature_hex: String.t(),
          timestamp_token: binary() | nil,
          tst_info: map() | nil
        }

  @type verify_result :: %{
          valid: boolean(),
          field_name: String.t() | nil,
          signer_cert_subject: String.t() | nil,
          pades_level: :b_b | :b_t | nil,
          has_timestamp: boolean(),
          timestamp_valid: boolean() | nil,
          message_imprint_match: boolean() | nil,
          byte_range_intact: boolean() | nil,
          warnings: [String.t()]
        }

  @placeholder_size 8192

  # Signature field attributes (reserved for future appearance generation)
  # @signature_filter_name "Adobe.PPKLite"
  # @signature_subfilter_adbe_pkcs7_detached "/adbe.pkcs7.detached"

  @doc """
  Signs a PDF document and returns the signed bytes together with metadata.

  The flow:
    1. Open the PDF with `Quire.Pdf`
    2. Allocate a signature field widget annotation on the target page
    3. Serialise with a placeholder for the CMS; compute the byte-range hash
    4. Build the CMS detached signature (B-B: signed attrs only;
       B-T: also fetch an RFC 3161 TimeStampToken from the configured TSA)
    5. Replace the placeholder with the real CMS; incremental-save

  Returns `{:ok, signature_result()}` or `{:error, reason}`.
  """
  @spec sign(binary(), signer(), sign_opts()) ::
          {:ok, signature_result()} | {:error, term()}
  def sign(pdf_bytes, signer, opts \\ []) do
    pades_level = Keyword.get(opts, :pades_level, :b_b)
    field_name = Keyword.get(opts, :field_name, "Signature1")
    field_rect = Keyword.get(opts, :field_rect, [72, 72, 216, 144])
    page_index = Keyword.get(opts, :page_index, 0)
    reason = Keyword.get(opts, :reason, "")
    location = Keyword.get(opts, :location, "")
    contact = Keyword.get(opts, :contact_info, "")
    tsa_url_override = Keyword.get(opts, :tsa_url)
    _appearance_png = Keyword.get(opts, :appearance_png)

    signer = normalize_signer(signer)

    with {:ok, doc} <- Quire.Pdf.open(pdf_bytes),
         {:ok, _field_ref} <-
           add_signature_field(doc, page_index, field_rect, field_name),
         {:ok, pre_save} <- Quire.Pdf.incremental_save(doc),
         {:ok, byte_range, content_hash} <-
           compute_byte_range(pre_save, @placeholder_size),
         {:ok, cms_der} <-
           build_cms(
             content_hash,
             signer,
             field_name,
             pades_level,
             reason,
             location,
             contact,
             tsa_url_override
           ),
         :ok <- validate_cms_fits(cms_der, @placeholder_size),
         final_bytes <- replace_placeholder(pre_save, byte_range, cms_der, @placeholder_size),
         {:ok, verifications} <- Validation.verify(final_bytes) do
      sig_hex = Base.encode16(:crypto.hash(:sha256, cms_der), case: :lower)

      result = %{
        signed_bytes: final_bytes,
        pades_level: pades_level,
        field_name: field_name,
        signature_hex: sig_hex,
        timestamp_token: verifications[:timestamp_token],
        tst_info: verifications[:tst_info]
      }

      {:ok, result}
    end
  end

  @doc """
  Signs a PDF with a PKCS#12 keystore.

  Convenience wrapper that parses the keystore, selects the first
  certificate+key pair, and delegates to `sign/3`.
  """
  @spec sign_with_pkcs12(binary(), binary(), String.t(), sign_opts()) ::
          {:ok, signature_result()} | {:error, term()}
  def sign_with_pkcs12(pdf_bytes, pfx_binary, password, opts \\ []) do
    case Pkcs12.parse(pfx_binary, password) do
      {:ok, keys, certs} when keys != [] and certs != [] ->
        key = List.first(keys)
        cert = List.first(certs)

        signer = %{
          certificate_der: cert.der,
          private_key_der: key.key_der,
          algorithm: key.algorithm
        }

        sign(pdf_bytes, signer, opts)

      {:ok, [], _} ->
        {:error, :no_private_key_in_keystore}

      {:ok, _, []} ->
        {:error, :no_certificate_in_keystore}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Verifies all signatures in a PDF.

  Returns `{:ok, [verify_result()]}` or `{:error, reason}`.
  """
  @spec verify(binary()) :: {:ok, [verify_result()]} | {:error, term()}
  def verify(pdf_bytes) when is_binary(pdf_bytes) do
    Validation.verify(pdf_bytes)
  end

  @doc """
  Parses a PKCS#12 keystore and returns certificates and keys without signing.

  Returns `{:ok, keys, certs}` where each key is `%{algorithm:, key_der:}` and
  each cert is `%{der:, key_id:}`.
  """
  @spec parse_keystore(binary(), String.t()) ::
          {:ok, [Pkcs12.private_key()], [Pkcs12.certificate()]} | {:error, term()}
  def parse_keystore(pfx_binary, password) do
    Pkcs12.parse(pfx_binary, password)
  end

  @doc false
  def check do
    if function_exported?(Quire.Pdf, :check, 0) do
      Quire.Pdf.check()
    else
      :ok
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────

  defp normalize_signer(%{algorithm: algo} = signer) when algo in [:rsa, :ecdsa], do: signer

  defp normalize_signer(signer) do
    algo = detect_algorithm(Map.get(signer, :private_key_der, <<>>))
    Map.put(signer, :algorithm, algo)
  end

  defp detect_algorithm(<<0x30, _len, rest::binary>>) do
    # Try to decode PKCS#8 PrivateKeyInfo
    case decode_pkcs8_algorithm(rest) do
      {:ok, algo} -> algo
      :error -> :rsa
    end
  end

  defp detect_algorithm(_), do: :rsa

  defp decode_pkcs8_algorithm(rest) do
    # PKCS#8 PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm AlgorithmIdentifier, ... }
    # AlgorithmIdentifier ::= SEQUENCE { algorithm OID, ... }
    with {{0x02, _version}, after_version} <- Cms.decode_tlv(rest),
         {{0x30, alg_seq}, _after_alg} <- Cms.decode_tlv(after_version),
         {{0x06, oid_bin}, _rest} <- Cms.decode_tlv(alg_seq) do
      oid = Tsa.decode_oid(oid_bin)

      case oid do
        {1, 2, 840, 113_549, 1, 1, 1} -> {:ok, :rsa}
        {1, 2, 840, 100_045, 2, 1} -> {:ok, :ecdsa}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  # ── PDF signature field creation ─────────────────────────────────────

  defp add_signature_field(doc, page_index, rect, field_name) do
    alias Quire.Pdf

    with {:ok, page_ref} <- page_ref_at(doc, page_index) do
      field_dict = %{
        "/Type" => {:name, "Annot"},
        "/Subtype" => {:name, "Widget"},
        "/FT" => {:name, "Sig"},
        "/Rect" => Enum.map(rect, fn n -> if is_integer(n), do: n * 1.0, else: n end),
        "/F" => 4,
        "/P" => page_ref,
        "/T" => Pdf.AcroForm.escape_pdf_string(field_name),
        "/V" => {:name, field_name},
        "/Ff" => 1
      }

      with {:ok, field_id} <- Pdf.allocate_object_id(doc),
           :ok <- Pdf.set_object(doc, {field_id, 0}, field_dict),
           :ok <- append_page_annot(Pdf, doc, page_ref, {:ref, field_id, 0}),
           :ok <- append_acroform_field(Pdf, doc, {:ref, field_id, 0}) do
        {:ok, {:ref, field_id, 0}}
      end
    end
  end

  defp page_ref_at(doc, page_index) do
    alias Quire.Pdf

    with {:ok, catalog} <- Pdf.catalog(doc) do
      case catalog["/Pages"] do
        {:ref, num, gen} ->
          refs = walk_page_tree(doc, {num, gen}, []) |> Enum.reverse()

          case Enum.at(refs, page_index) do
            nil -> {:error, :page_not_found}
            ref -> {:ok, ref}
          end

        _ ->
          {:error, :page_tree_missing}
      end
    end
  end

  defp walk_page_tree(doc, {num, gen}, acc) do
    case Quire.Pdf.get_object(doc, {num, gen}) do
      {:ok, dict} ->
        case dict["/Type"] do
          {:name, "Page"} ->
            [{:ref, num, gen} | acc]

          {:name, "Pages"} ->
            dict
            |> Map.get("/Kids", [])
            |> Enum.reduce(acc, fn
              {:ref, knum, kgen}, inner_acc ->
                walk_page_tree(doc, {knum, kgen}, inner_acc)

              _, inner_acc ->
                inner_acc
            end)

          _ ->
            acc
        end

      {:error, _} ->
        acc
    end
  end

  defp append_page_annot(pdf_module, doc, page_ref, widget_ref) do
    {num, gen} = page_ref_id(page_ref)

    with {:ok, page} <- pdf_module.get_object(doc, {num, gen}) do
      annots = Map.get(page, "/Annots", []) |> List.wrap()
      pdf_module.set_object(doc, {num, gen}, Map.put(page, "/Annots", annots ++ [widget_ref]))
    end
  end

  defp append_acroform_field(pdf_module, doc, field_ref) do
    with {:ok, catalog} <- pdf_module.catalog(doc) do
      {acroform, id} =
        case catalog do
          %{"/AcroForm" => {:ref, num, gen}} ->
            case pdf_module.get_object(doc, {num, gen}) do
              {:ok, af} -> {af, {num, gen}}
              _ -> {%{}, nil}
            end

          _ ->
            {%{}, nil}
        end

      fields = Map.get(acroform, "/Fields", []) |> List.wrap()
      fields = Enum.uniq(fields ++ [field_ref])

      {acroform, id} = ensure_acroform(doc, acroform, id)

      acroform =
        acroform
        |> Map.put("/Fields", fields)
        |> Map.put("/SigFlags", 3)

      {num, gen} =
        case id do
          nil ->
            {:ok, fresh} = pdf_module.allocate_object_id(doc)
            {fresh, 0}

          {n, g} ->
            {n, g}
        end

      with :ok <- pdf_module.set_object(doc, {num, gen}, acroform) do
        updated = Map.put(catalog, "/AcroForm", {:ref, num, gen})
        pdf_module.set_object(doc, 1, updated)
      end
    end
  end

  defp ensure_acroform(_doc, acroform, id) when acroform != %{}, do: {acroform, id}

  defp ensure_acroform(doc, _, nil) do
    with {:ok, font_id} <- Quire.Pdf.allocate_object_id(doc) do
      font_dict = %{
        "/Type" => {:name, "Font"},
        "/Subtype" => {:name, "Type1"},
        "/BaseFont" => {:name, "Helvetica"}
      }

      :ok = Quire.Pdf.set_object(doc, {font_id, 0}, font_dict)
      dr = %{"/Font" => %{"/Helv" => {:ref, font_id, 0}}}

      {%{"/DR" => dr, "/NeedAppearances" => true}, nil}
    end
  end

  defp page_ref_id({:ref, num, gen}), do: {num, gen}
  defp page_ref_id({num, gen}), do: {num, gen}

  # ── Byte-range computation ───────────────────────────────────────────

  defp compute_byte_range(pre_save, placeholder_size) do
    # Find the placeholder in the incremental save and compute the byte ranges
    # that exclude the placeholder bytes.
    placeholder = String.duplicate(<<0>>, placeholder_size)
    total = byte_size(pre_save)
    placeholder_pos = find_placeholder(pre_save, placeholder)

    if placeholder_pos do
      range_before = placeholder_pos
      range_after_start = placeholder_pos + placeholder_size
      range_after_len = total - range_after_start

      byte_range = [0, range_before, range_after_start, range_after_len]

      # Hash everything except the placeholder
      hash_data =
        binary_part(pre_save, 0, range_before) <>
          binary_part(pre_save, range_after_start, range_after_len)

      content_hash = :crypto.hash(:sha256, hash_data)
      {:ok, byte_range, content_hash}
    else
      {:error, :placeholder_not_found}
    end
  end

  defp find_placeholder(pdf, placeholder) do
    case :binary.match(pdf, placeholder) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
  end

  defp replace_placeholder(pre_save, byte_range, cms_der, placeholder_size) do
    placeholder = String.duplicate(<<0>>, placeholder_size)
    hex_cms = Base.encode16(cms_der, case: :lower)

    # Build the /ByteRange and /Contents entries
    byte_range_str =
      "[#{Enum.join(byte_range, " ")}]"

    contents_str = "<#{hex_cms}>"

    # Find the placeholder location
    placeholder_pos = find_placeholder(pre_save, placeholder)

    if placeholder_pos do
      # Split the pre_save around the placeholder
      before = binary_part(pre_save, 0, placeholder_pos)
      _placeholder = binary_part(pre_save, placeholder_pos, placeholder_size)

      after_start = placeholder_pos + placeholder_size
      after_part = binary_part(pre_save, after_start, byte_size(pre_save) - after_start)

      # Replace /ByteRange [...] with actual byte range
      after_part =
        String.replace(after_part, "/ByteRange [0 0 0 0]", "/ByteRange #{byte_range_str}",
          global: false
        )

      # Replace /Contents <00...> with actual signature
      # The placeholder in the PDF is hex-encoded zeros, e.g. <0000...>
      hex_placeholder = String.duplicate("00", placeholder_size)
      after_part = String.replace(after_part, "<#{hex_placeholder}>", contents_str, global: false)

      before <> after_part
    else
      pre_save
    end
  end

  # ── CMS construction ─────────────────────────────────────────────────

  defp build_cms(
         content_hash,
         signer,
         _field_name,
         pades_level,
         _reason,
         _location,
         _contact,
         tsa_url_override
       ) do
    sign_fun = fn digest ->
      signer_key = decode_private_key(signer.private_key_der, signer.algorithm)

      sig =
        case signer.algorithm do
          :rsa ->
            :public_key.sign(digest, :sha256, signer_key)

          :ecdsa ->
            :public_key.sign(digest, :sha256, signer_key)
        end

      {:ok, sig}
    end

    cms_opts =
      [
        signature_algorithm: signer.algorithm,
        signing_time: DateTime.utc_now()
      ]

    cms_opts =
      if pades_level == :b_t do
        tsa_url = tsa_url_override || tsa_config_url()

        case Tsa.request(content_hash, tsa_url: tsa_url) do
          {:ok, %{token: token}} ->
            Keyword.put(cms_opts, :timestamp_token, token)

          {:error, reason} ->
            # Warn but continue — we get B-B anyway
            require Logger
            Logger.warning("TSA request failed: #{inspect(reason)}")
            cms_opts
        end
      else
        cms_opts
      end

    Cms.build_bes_signed_data(content_hash, signer.certificate_der, sign_fun, cms_opts)
  end

  defp tsa_config_url do
    Application.get_env(:quire, :pades, [])[:tsa_url] || ""
  end

  defp decode_private_key(key_der, :rsa) do
    # Decode PKCS#8 → RSAPrivateKey
    decoded = :public_key.der_decode(:RSAPrivateKey, extract_pkcs8_private(key_der))
    decoded
  end

  defp decode_private_key(key_der, :ecdsa) do
    decoded = :public_key.der_decode(:ECPrivateKey, extract_pkcs8_private(key_der))
    decoded
  end

  defp extract_pkcs8_private(key_der) do
    # PKCS#8 PrivateKeyInfo ::= SEQUENCE { version, algorithm, privateKey OCTET STRING }
    result =
      case split_tlv(key_der) do
        {:ok, {0x30, _l, content, ""}} ->
          # Walk: version (INTEGER), algorithm (SEQUENCE), privateKey (OCTET STRING)
          rest = tlvs(content)

          case Enum.find(rest, fn {t, _} -> t == 0x04 end) do
            {0x04, key_data} -> key_data
            nil -> key_der
          end

        _ ->
          key_der
      end

    result
  end

  defp split_tlv(<<tag, len::8, rest::binary>>) when len < 0x80 do
    <<content::binary-size(^len), rest::binary>> = rest
    {:ok, {tag, len, content, rest}}
  end

  defp split_tlv(<<tag, 0x81, len::8, rest::binary>>) do
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

  defp tlvs(<<>>), do: []

  defp tlvs(bin) do
    case split_tlv(bin) do
      {:ok, {t, _l, c, rest}} -> [{t, c} | tlvs(rest)]
      :error -> []
    end
  end

  defp validate_cms_fits(cms_der, placeholder_size) do
    cms_size = byte_size(cms_der)

    if cms_size > placeholder_size do
      {:error, {:cms_too_large, cms_size, placeholder_size}}
    else
      :ok
    end
  end
end
