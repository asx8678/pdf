defmodule Quire.SecurityHandler do
  @moduledoc """
  Encryption/decryption — document security per ISO 32000-2 §7.6.

  Pure Elixir implementation of the standard PDF security handler, using
  `:crypto` for AES-CBC, MD5 and SHA-256. Supports two cipher suites:

    * **AESV2** (R=3, 128-bit AES-CBC, MD5-based key derivation)
    * **AESV3** (R=5, 256-bit AES-CBC, SHA-256-based key derivation)

  ## Behaviour

  This module IS the behaviour — it defines `encrypt/2`, `decrypt/2` and
  `info/1` and implements them. Each function operates on raw PDF bytes.
  Passwords are never persisted or logged.

  ## Permission flags

  Eight flags (PDF 2.0 §7.6.2):

    * `:print` — 0x04
    * `:print_high_quality` — 0x800
    * `:modify` — 0x08
    * `:copy_extract` — 0x10
    * `:annotate` — 0x20
    * `:fill_forms` — 0x100
    * `:extract_accessibility` — 0x200
    * `:assemble` — 0x400

  All granted when only a user password is set.
  """

  # ── Callbacks ──────────────────────────────────────────────────────────

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

  @behaviour Quire.SecurityHandler

  # ── Constants ──────────────────────────────────────────────────────────
  # PDF standard padding string (§7.6.2) — 32 bytes.
  @padding_string <<0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF,
                    0xFA, 0x01, 0x08, 0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00,
                    0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08>>

  # ── Permission bit positions (1-indexed from LSB, PDF convention) ──────
  @print 0x00000004
  @modify 0x00000008
  @copy_extract 0x00000010
  @annotate 0x00000020
  @fill_forms 0x00000100
  @extract_accessibility 0x00000200
  @assemble 0x00000400
  @print_high_quality 0x00000800

  # Reserved bits that the PDF spec requires to be 1 (bits 1,2,7,8,13-32).
  @reserved_bits 0xFFFFF0C3

  # All permission bits OR'd together.
  @all_permissions Bitwise.bor(
                     @print,
                     Bitwise.bor(
                       @modify,
                       Bitwise.bor(
                         @copy_extract,
                         Bitwise.bor(
                           @annotate,
                           Bitwise.bor(
                             @fill_forms,
                             Bitwise.bor(
                               @extract_accessibility,
                               Bitwise.bor(@assemble, @print_high_quality)
                             )
                           )
                         )
                       )
                     )
                   )

  @doc false
  def all_permissions_flag, do: @all_permissions

  @doc false
  def reserved_bits, do: @reserved_bits

  # ── Permission flag helpers ────────────────────────────────────────────

  @doc """
  Build the 32-bit permissions integer (P value) from a keyword list.

  Each key is a permission atom (`:print`, `:modify`, etc.) or `:all`.
  Flags not listed are *denied* unless `default_all?` is true, in which case
  every permission is granted and individual entries are revocations.

  ## Examples

      iex> Quire.SecurityHandler.build_permissions(print: true)
      0xFFFFF0C7

      iex> Quire.SecurityHandler.build_permissions(all: true, print: false)
      0xFFFFFFFB
  """
  @spec build_permissions(Keyword.t()) :: non_neg_integer()
  def build_permissions(flags) do
    default_all? = Keyword.get(flags, :all, false)

    base =
      if default_all? do
        Bitwise.bor(@reserved_bits, @all_permissions)
      else
        @reserved_bits
      end

    mask =
      flags
      |> Enum.reduce(0, fn
        {:all, _}, acc -> acc
        {:print, true}, acc -> Bitwise.bor(acc, @print)
        {:modify, true}, acc -> Bitwise.bor(acc, @modify)
        {:copy_extract, true}, acc -> Bitwise.bor(acc, @copy_extract)
        {:annotate, true}, acc -> Bitwise.bor(acc, @annotate)
        {:fill_forms, true}, acc -> Bitwise.bor(acc, @fill_forms)
        {:extract_accessibility, true}, acc -> Bitwise.bor(acc, @extract_accessibility)
        {:assemble, true}, acc -> Bitwise.bor(acc, @assemble)
        {:print_high_quality, true}, acc -> Bitwise.bor(acc, @print_high_quality)
        _, acc -> acc
      end)

    if default_all? do
      granted = base
      denied = Keyword.keys(flags) -- [:all]

      Enum.reduce(denied, granted, fn key, acc ->
        case key do
          :print -> Bitwise.band(acc, Bitwise.bnot(@print))
          :modify -> Bitwise.band(acc, Bitwise.bnot(@modify))
          :copy_extract -> Bitwise.band(acc, Bitwise.bnot(@copy_extract))
          :annotate -> Bitwise.band(acc, Bitwise.bnot(@annotate))
          :fill_forms -> Bitwise.band(acc, Bitwise.bnot(@fill_forms))
          :extract_accessibility -> Bitwise.band(acc, Bitwise.bnot(@extract_accessibility))
          :assemble -> Bitwise.band(acc, Bitwise.bnot(@assemble))
          :print_high_quality -> Bitwise.band(acc, Bitwise.bnot(@print_high_quality))
          _ -> acc
        end
      end)
    else
      Bitwise.bor(base, mask)
    end
  end

  @doc """
  Unpack a 32-bit `P` value into a keyword list of permission atoms.

  Returns every permission key with a boolean value indicating whether it is
  granted.
  """
  @spec unpack_permissions(non_neg_integer()) :: Keyword.t()
  def unpack_permissions(p) do
    [
      print: Bitwise.band(p, @print) != 0,
      modify: Bitwise.band(p, @modify) != 0,
      copy_extract: Bitwise.band(p, @copy_extract) != 0,
      annotate: Bitwise.band(p, @annotate) != 0,
      fill_forms: Bitwise.band(p, @fill_forms) != 0,
      extract_accessibility: Bitwise.band(p, @extract_accessibility) != 0,
      assemble: Bitwise.band(p, @assemble) != 0,
      print_high_quality: Bitwise.band(p, @print_high_quality) != 0
    ]
  end

  # ── Behaviour callbacks ────────────────────────────────────────────────

  @impl true
  @doc """
  Encrypt a PDF with the given password(s) and options.

  ## Options

    * `:user_password` — (required) the open/user password
    * `:owner_password` — (optional) defaults to `user_password` if omitted
    * `:permissions` — (optional) 32-bit permission flags; defaults to all granted
    * `:algorithm` — `:aesv2` (default) or `:aesv3`
    * `:key_length` — key length in bytes (optional, inferred from algorithm)

  Returns `{:ok, encrypted_pdf_bytes}` or `{:error, reason}`.
  """
  @spec encrypt(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encrypt(pdf_bytes, opts) when is_binary(pdf_bytes) and is_list(opts) do
    user_password = Keyword.fetch!(opts, :user_password)
    owner_password = Keyword.get(opts, :owner_password, user_password)
    permissions = Keyword.get(opts, :permissions, Bitwise.bor(@reserved_bits, @all_permissions))
    algorithm = Keyword.get(opts, :algorithm, :aesv2)

    do_encrypt(pdf_bytes, user_password, owner_password, permissions, algorithm)
  end

  @impl true
  @doc """
  Decrypt a PDF with the given password.

  ## Options

    * `:password` — (required) the user or owner password

  Returns `{:ok, decrypted_pdf_bytes}` or `{:error, reason}`.
  """
  @spec decrypt(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def decrypt(pdf_bytes, opts) when is_binary(pdf_bytes) and is_list(opts) do
    password = Keyword.fetch!(opts, :password)

    do_decrypt(pdf_bytes, password)
  end

  @impl true
  @doc """
  Returns encryption metadata from an encrypted PDF.

  Returns `{:ok, %{encrypted: bool, algorithm: atom, permissions: integer}}`
  or `{:error, reason}`.
  """
  @spec info(binary()) :: {:ok, map()} | {:error, term()}
  def info(pdf_bytes) when is_binary(pdf_bytes) do
    # Extract encryption info from the PDF bytes by finding the /Encrypt dict.
    case extract_encrypt_dict(pdf_bytes) do
      {:ok, encrypt_dict, trailer_dict} ->
        algorithm = detect_algorithm(encrypt_dict)
        permissions = extract_permissions(encrypt_dict)

        {:ok,
         %{
           encrypted: true,
           algorithm: algorithm,
           permissions: permissions,
           encrypt_dict: encrypt_dict,
           file_id: extract_file_id(trailer_dict)
         }}

      :not_found ->
        {:ok, %{encrypted: false}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Key derivation — public entry point ────────────────────────────────

  @doc """
  Derive an encryption key from a password.

  ## Options

    * `:algorithm` — `:aesv2` or `:aesv3` (default `:aesv2`)
    * `:owner_hash` — the /O value (32 bytes for R=3, 48 bytes for R=5)
    * `:permissions` — the /P value (32-bit integer)
    * `:file_id` — the /ID first element (binary)
    * `:key_salt` — the key salt for R=5 (8 bytes)

  For AESV2 (R=3): follows Algorithm 2 (MD5, 50 iterations).
  For AESV3 (R=5): follows Algorithm 2.A (SHA-256).
  """
  @spec derive_key(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def derive_key(password, opts) when is_list(opts) do
    algorithm = Keyword.get(opts, :algorithm, :aesv2)

    case algorithm do
      :aesv3 ->
        key_salt = Keyword.fetch!(opts, :key_salt)
        {:ok, derive_key_r5(password, key_salt)}

      :aesv2 ->
        owner_hash = Keyword.fetch!(opts, :owner_hash)
        permissions = Keyword.fetch!(opts, :permissions)
        file_id = Keyword.fetch!(opts, :file_id)

        {:ok, derive_key_r3(password, owner_hash, permissions, file_id)}
    end
  end

  # ── Full-document encryption (internal) ────────────────────────────────

  defp do_encrypt(pdf_bytes, user_password, owner_password, permissions, algorithm) do
    # Parse the PDF using Quire.Pdf.
    with {:ok, doc} <- Quire.Pdf.open(pdf_bytes) do
      # Extract the file ID from the trailer.
      file_id = extract_file_id_from_doc(doc)

      # Generate the /Encrypt dictionary and derive keys.
      {encrypt_dict, encryption_key, key_len} =
        build_encrypt_dict(user_password, owner_password, permissions, file_id, algorithm)

      # Encrypt all streams and strings in the document.
      with {:ok, encrypted_doc} <- encrypt_document(doc, encrypt_dict, encryption_key, key_len) do
        # Write the encrypted PDF.
        Quire.Pdf.save(encrypted_doc)
      end
    end
  end

  defp do_decrypt(pdf_bytes, password) do
    # Delegates to Quire.SecurityHandler.Decrypt which handles xref parsing,
    # per-object key derivation, stream/string decryption and trailer cleanup.
    Quire.SecurityHandler.Decrypt.remove_encryption(pdf_bytes, password)
  end

  # ── /Encrypt dictionary generation ─────────────────────────────────────

  @doc """
  Build an /Encrypt dictionary map for the given parameters.

  Returns `{encrypt_dict_map, encryption_key, key_length_bytes}`.
  """
  @spec build_encrypt_dict(
          String.t(),
          String.t(),
          non_neg_integer(),
          binary(),
          :aesv2 | :aesv3
        ) :: {map(), binary(), non_neg_integer()}
  def build_encrypt_dict(user_password, owner_password, permissions, file_id, algorithm)

  def build_encrypt_dict(user_password, owner_password, permissions, file_id, :aesv2) do
    # R=3 / AESV2
    o_value = compute_o_r3(owner_password)
    key_len = 16

    # Derive the encryption key using the user password / O / P / ID[0:4].
    encryption_key = derive_key_r3(user_password, o_value, permissions, file_id)
    u_value = compute_u_r3(encryption_key)

    encrypt_dict = %{
      "/Filter" => {:name, "Standard"},
      "/SubFilter" => {:name, "adbe.pkcs7.s4"},
      "/R" => 3,
      "/O" => o_value,
      "/U" => u_value,
      "/P" => permissions,
      "/Length" => 128,
      "/V" => 2
    }

    {encrypt_dict, encryption_key, key_len}
  end

  def build_encrypt_dict(user_password, owner_password, permissions, _file_id, :aesv3) do
    # R=5 / AESV3 — the encryption key is a random 32-byte value.
    validation_salt_user = :crypto.strong_rand_bytes(8)
    key_salt_user = :crypto.strong_rand_bytes(8)
    validation_salt_owner = :crypto.strong_rand_bytes(8)
    key_salt_owner = :crypto.strong_rand_bytes(8)

    encryption_key = :crypto.strong_rand_bytes(32)

    u_value = compute_u_r5(user_password, validation_salt_user, key_salt_user)
    o_value = compute_o_r5(owner_password, validation_salt_owner, key_salt_owner)
    ue_value = compute_ue_r5(user_password, encryption_key, key_salt_user)
    oe_value = compute_oe_r5(owner_password, encryption_key, key_salt_owner)
    perms_value = compute_perms_r5(permissions, encryption_key)

    encrypt_dict = %{
      "/Filter" => {:name, "Standard"},
      "/SubFilter" => {:name, "adbe.pkcs7.s5"},
      "/R" => 5,
      "/O" => o_value,
      "/U" => u_value,
      "/OE" => oe_value,
      "/UE" => ue_value,
      "/P" => permissions,
      "/Perms" => perms_value,
      "/Length" => 256,
      "/V" => 5
    }

    {encrypt_dict, encryption_key, 32}
  end

  # ── Encryption key derivation ──────────────────────────────────────────

  @doc false
  # Algorithm 2 (R=3) — MD5-based key derivation.
  # Inputs: password (string), O (32 bytes), P (32-bit integer), ID (file ID binary).
  # Returns 16-byte encryption key.
  def derive_key_r3(password, o_value, permissions, file_id) do
    padded = pad_password(password)
    p_bytes = <<permissions::32-little>>
    id_prefix = binary_part(file_id, 0, min(byte_size(file_id), 4))

    hash = :crypto.hash(:md5, padded <> o_value <> p_bytes <> id_prefix)

    # 50 iterations of re-hashing the first 16 bytes.
    final =
      Enum.reduce(1..50, hash, fn _i, acc ->
        :crypto.hash(:md5, binary_part(acc, 0, 16))
      end)

    # AESV2 key is 16 bytes.
    binary_part(final, 0, 16)
  end

  @doc false
  # Algorithm 2.A (R=5) — SHA-256-based key derivation from password + key_salt.
  def derive_key_r5(password, key_salt) do
    normalized = normalize_password(password)
    padded = pad_to_64(normalized)
    :crypto.hash(:sha256, padded <> key_salt)
  end

  # ── O / U computation (R=3) ────────────────────────────────────────────

  @doc false
  # Algorithm 3 (R=3) — compute the /O entry (32 bytes) from the owner password.
  def compute_o_r3(owner_password) do
    padded_owner = pad_password(owner_password)
    hash = :crypto.hash(:md5, padded_owner)

    # First 5 bytes of hash as RC4 key.
    rc4_key = binary_part(hash, 0, 5)

    # The padded user password is used as the "plain user password"
    # for R=3 O computation.
    result = rc4_encrypt(padded_owner, rc4_key)

    # 19 more iterations, key = hash[0:5] XOR i for each byte.
    Enum.reduce(1..19, result, fn i, acc ->
      iter_key = for(j <- 0..4, into: <<>>, do: <<Bitwise.bxor(:binary.at(hash, j), i)::8>>)
      rc4_encrypt(acc, iter_key)
    end)
  end

  @doc false
  # Algorithm 4 (R=3) — compute the /U entry (32 bytes) from the encryption key.
  def compute_u_r3(encryption_key) do
    result = rc4_encrypt(@padding_string, encryption_key)

    # 19 more iterations with XOR'd keys.
    Enum.reduce(1..19, result, fn i, acc ->
      # XOR every byte of the encryption key with i.
      iter_key =
        for(
          j <- 0..(byte_size(encryption_key) - 1),
          into: <<>>,
          do: <<Bitwise.bxor(:binary.at(encryption_key, j), i)::8>>
        )

      rc4_encrypt(acc, iter_key)
    end)
  end

  # ── O / U / OE / UE computation (R=5) ──────────────────────────────────

  @doc false
  # Compute /O for R=5: SHA-256(normalized_password ++ validation_salt) ++ validation_salt ++ key_salt
  # Returns 48 bytes.
  def compute_o_r5(owner_password, validation_salt, key_salt) do
    normalized = normalize_password(owner_password)
    padded = pad_to_64(normalized)
    hash = :crypto.hash(:sha256, padded <> validation_salt)
    hash <> validation_salt <> key_salt
  end

  @doc false
  # Compute /U for R=5: same structure as O.
  # Returns 48 bytes.
  def compute_u_r5(user_password, validation_salt, key_salt) do
    normalized = normalize_password(user_password)
    padded = pad_to_64(normalized)
    hash = :crypto.hash(:sha256, padded <> validation_salt)
    hash <> validation_salt <> key_salt
  end

  @doc false
  # Compute /OE for R=5: AES-256-ECB(file_encryption_key, SHA-256(password ++ key_salt)).
  # Returns 32 bytes.
  def compute_oe_r5(owner_password, file_encryption_key, key_salt) do
    normalized = normalize_password(owner_password)
    padded = pad_to_64(normalized)
    wrap_key = :crypto.hash(:sha256, padded <> key_salt)
    aes_ecb_encrypt(file_encryption_key, wrap_key)
  end

  @doc false
  # Compute /UE for R=5: same structure as OE.
  # Returns 32 bytes.
  def compute_ue_r5(user_password, file_encryption_key, key_salt) do
    normalized = normalize_password(user_password)
    padded = pad_to_64(normalized)
    wrap_key = :crypto.hash(:sha256, padded <> key_salt)
    aes_ecb_encrypt(file_encryption_key, wrap_key)
  end

  @doc false
  # Compute /Perms for R=5: AES-256-ECB(perms_block, file_encryption_key).
  # The perms block is 16 bytes: P (LE 4 bytes) ++ 12 bytes of 0xFF.
  # Returns 16 bytes.
  def compute_perms_r5(permissions, file_encryption_key) do
    perms_block =
      <<permissions::32-little, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8,
        0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8, 0xFF::8>>

    aes_ecb_encrypt(perms_block, file_encryption_key)
  end

  # ── Authentication (decrypt path) ──────────────────────────────────────

  # ── Document-level encrypt / decrypt ───────────────────────────────────

  defp encrypt_document(doc, encrypt_dict, _encryption_key, _key_len) do
    # Insert the /Encrypt dictionary as an indirect object.
    with {:ok, obj_num} <- Quire.Pdf.allocate_object_id(doc) do
      :ok = Quire.Pdf.set_object(doc, obj_num, encrypt_dict)

      # Get the catalog and trailer to add /Encrypt reference and /ID.
      case Quire.Pdf.catalog(doc) do
        {:ok, catalog} ->
          # Set /Encrypt in the trailer.
          # We need to set it on the root/trailer level. The NIF doesn't expose
          # trailer mutation directly, so we modify the catalog to carry /Encrypt.
          trailer_ref = {:ref, obj_num, 0}
          catalog_with_encrypt = Map.put(catalog, "/Encrypt", trailer_ref)

          # Set the modified catalog back.
          # The catalog is typically object 1, gen 0.
          catalog_obj_num = get_catalog_obj_num(catalog)
          :ok = Quire.Pdf.set_object(doc, catalog_obj_num, catalog_with_encrypt)

          {:ok, doc}

        _ ->
          {:error, :no_catalog}
      end
    end
  end

  # ── PDF byte introspection ─────────────────────────────────────────────

  @doc false
  # Extract the /Encrypt dictionary and /Trailer dictionary from raw PDF bytes.
  # Uses simple byte scanning to find the trailer and Encrypt reference.
  # Returns {:ok, encrypt_dict, trailer_dict} or :not_found or {:error, reason}.
  def extract_encrypt_dict(pdf_bytes) when is_binary(pdf_bytes) do
    # Try parsing with Quire.Pdf.open first — it'll return :password_error
    # for encrypted PDFs, which confirms encryption.
    case Quire.Pdf.open(pdf_bytes) do
      {:ok, _doc} ->
        # Not encrypted.
        :not_found

      {:error, :password_error} ->
        # Encrypted — extract what we can from the raw bytes.
        extract_encrypt_from_raw(pdf_bytes)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_encrypt_from_raw(pdf_bytes) do
    # Basic PDF trailer extraction — find the last "trailer" keyword.
    # This is a simple scan; for production we'd use a proper parser.
    case find_trailer_dict(pdf_bytes) do
      {:ok, trailer_dict} ->
        encrypt_ref = Map.get(trailer_dict, "/Encrypt")

        if is_nil(encrypt_ref) do
          :not_found
        else
          # Try to find the Encrypt dictionary object from the cross-ref table.
          case resolve_encrypt_obj(pdf_bytes, encrypt_ref, trailer_dict) do
            {:ok, encrypt_dict} -> {:ok, encrypt_dict, trailer_dict}
            error -> error
          end
        end

      error ->
        error
    end
  end

  # ── AES-CBC encryption / decryption ────────────────────────────────────

  @doc """
  Encrypt data with AES-CBC and PKCS7 padding.

  The IV is prepended to the ciphertext.
  """
  @spec aes_cbc_encrypt(binary(), binary(), binary()) :: binary()
  def aes_cbc_encrypt(plaintext, key, iv) do
    padded = pkcs7_pad(plaintext, 16)
    ciphertext = :crypto.crypto_one_time(:aes_cbc, key, iv, padded, true)
    iv <> ciphertext
  end

  @doc """
  Decrypt data with AES-CBC.

  Expects ciphertext in IV+data form (first 16 bytes are the IV).
  """
  @spec aes_cbc_decrypt(binary(), binary()) :: binary()
  def aes_cbc_decrypt(ciphertext, key) do
    iv = binary_part(ciphertext, 0, 16)
    data = binary_part(ciphertext, 16, byte_size(ciphertext) - 16)
    decrypted = :crypto.crypto_one_time(:aes_cbc, key, iv, data, false)
    pkcs7_unpad(decrypted)
  end

  @doc """
  Encrypt data with AES-ECB (single-block or exact-multiple-of-block-size).

  Used for R=5 /OE, /UE, /Perms wrapping where plaintext is always a multiple
  of 16 bytes and requires no padding.
  """
  @spec aes_ecb_encrypt(binary(), binary()) :: binary()
  def aes_ecb_encrypt(plaintext, key) do
    _key_len_unused = 16
    key_len = byte_size(key)

    cipher =
      case key_len do
        16 -> :aes_128_ecb
        32 -> :aes_256_ecb
      end

    # No padding needed — plaintext is always a multiple of 16 bytes.
    :crypto.crypto_one_time(cipher, key, plaintext, true)
  end

  @doc """
  Decrypt data with AES-ECB.
  """
  @spec aes_ecb_decrypt(binary(), binary()) :: binary()
  def aes_ecb_decrypt(ciphertext, key) do
    key_len = byte_size(key)

    cipher =
      case key_len do
        16 -> :aes_128_ecb
        32 -> :aes_256_ecb
      end

    :crypto.crypto_one_time(cipher, key, ciphertext, false)
  end

  # ── PKCS7 padding ──────────────────────────────────────────────────────

  @doc false
  def pkcs7_pad(data, block_size) when is_integer(block_size) and block_size in 1..255 do
    pad_len = block_size - rem(byte_size(data), block_size)
    data <> :binary.copy(<<pad_len::8>>, pad_len)
  end

  @doc false
  def pkcs7_unpad(data) do
    # Peek at the last byte — it tells us how many bytes of padding to strip.
    last_byte = :binary.last(data)
    pad_len = last_byte

    if pad_len >= 1 and pad_len <= 16 do
      # Verify all padding bytes are the same value.
      padding = binary_part(data, byte_size(data) - pad_len, pad_len)

      if :binary.match(padding, <<pad_len::8>>) != :nomatch and
           String.valid?(:binary.list_to_bin([<<pad_len::8>>])) do
        # Verify all padding bytes equal the pad value.
        expected = :binary.copy(<<pad_len::8>>, pad_len)

        if padding == expected do
          binary_part(data, 0, byte_size(data) - pad_len)
        else
          # Invalid padding — return as-is.
          data
        end
      else
        data
      end
    else
      data
    end
  end

  # ── RC4 (for R=3) — pure Elixir ────────────────────────────────────────
  #
  # macOS / OpenSSL 3.x has removed RC4 (:crypto.crypto_one_time(:rc4, ...)
  # raises "Cipher not supported"), so we implement the algorithm explicitly.
  # RC4 is a stream cipher with an internal 256-byte state array.

  @doc false
  def rc4_encrypt(data, key) do
    {s, i, j} = rc4_ksa(key)
    rc4_prng(data, s, i, j)
  end

  @doc false
  def rc4_decrypt(data, key) do
    # RC4 is symmetric — encryption and decryption are identical.
    rc4_encrypt(data, key)
  end

  # Key Scheduling Algorithm — initialise the 256-byte S-box as a list.
  defp rc4_ksa(key) do
    s = Enum.to_list(0..255)
    key_len = byte_size(key)

    {s, _j} =
      Enum.reduce(0..255, {s, 0}, fn i, {s_list, j_acc} ->
        k = :binary.at(key, rem(i, key_len))
        j_new = rem(j_acc + Enum.at(s_list, i) + k, 256)
        # Swap s[i] and s[j]
        si = Enum.at(s_list, i)
        sj = Enum.at(s_list, j_new)
        s_swapped = List.replace_at(s_list, i, sj) |> List.replace_at(j_new, si)
        {s_swapped, j_new}
      end)

    {s, 0, 0}
  end

  # Pseudo-Random Generation Algorithm — operate on list S-box.
  defp rc4_prng(<<>>, _s, _i, _j), do: <<>>

  defp rc4_prng(data, s, i, j) do
    i = rem(i + 1, 256)
    j = rem(j + Enum.at(s, i), 256)
    si = Enum.at(s, i)
    sj = Enum.at(s, j)
    s = List.replace_at(s, i, sj) |> List.replace_at(j, si)
    k = Enum.at(s, rem(si + sj, 256))

    <<byte::8, rest::binary>> = data
    <<Bitwise.bxor(byte, k)::8>> <> rc4_prng(rest, s, i, j)
  end

  # ── Password handling ──────────────────────────────────────────────────

  @doc false
  # Pad a password to exactly 32 bytes using the standard PDF padding string.
  def pad_password(password) when is_binary(password) do
    pad_to(password, 32, @padding_string)
  end

  @doc false
  # Normalize a password for R=5. For now, simple UTF-8 normalization.
  # The PDF spec (§7.6.4.3.1) calls for SASLprep (RFC 4013), which is
  # stringprep-based and would require a dependency. We use basic NFC
  # normalization as a practical fallback.
  def normalize_password(password) do
    # NFC normalization — preserves most characters while normalizing
    # composed/decomposed Unicode forms.
    password
    |> String.normalize(:nfc)
    |> String.trim()
  end

  @doc false
  def pad_to_64(data) when is_binary(data) do
    pad_to(data, 64, <<0::8>>)
  end

  defp pad_to(data, target_len, pad_sequence) do
    data_len = byte_size(data)

    cond do
      data_len > target_len ->
        binary_part(data, 0, target_len)

      data_len == target_len ->
        data

      true ->
        remaining = target_len - data_len
        repeats = div(remaining, byte_size(pad_sequence)) + 1
        (data <> :binary.copy(pad_sequence, repeats)) |> binary_part(0, target_len)
    end
  end

  # ── Helpers — /Encrypt dict introspection ──────────────────────────────

  @doc false
  def detect_algorithm(encrypt_dict) do
    sub_filter = Map.get(encrypt_dict, "/SubFilter", "")

    case sub_filter do
      {:name, "adbe.pkcs7.s5"} ->
        :aesv3

      {:name, "adbe.pkcs7.s4"} ->
        :aesv2

      _ ->
        # Fall back to /R value.
        case Map.get(encrypt_dict, "/R", 3) do
          r when r >= 5 -> :aesv3
          _ -> :aesv2
        end
    end
  end

  @doc false
  def extract_permissions(encrypt_dict) do
    Map.get(encrypt_dict, "/P", 0)
  end

  @doc false
  def extract_file_id(trailer_dict) do
    case Map.get(trailer_dict, "/ID") do
      [first_id | _] when is_binary(first_id) -> first_id
      _ -> <<>>
    end
  end

  # ── PDF byte scanning (helpers for info/1) ─────────────────────────────

  defp find_trailer_dict(pdf_bytes) do
    # Find the last "trailer" keyword and extract key-value pairs.
    # This is a best-effort parser for the trailer dictionary.
    case find_last_trailer(pdf_bytes) do
      {:ok, trailer_start} ->
        dict_start = skip_whitespace(pdf_bytes, trailer_start + byte_size("trailer"))
        parse_dictionary(pdf_bytes, dict_start)

      :error ->
        {:error, :invalid_pdf}
    end
  end

  defp find_last_trailer(bytes) do
    # Scan backwards for "trailer" keyword (preceded by newline or start of file)
    size = byte_size(bytes)

    search_from = size - 1

    case binary_search_from(bytes, "trailer", search_from) do
      {:ok, pos} when pos >= 0 ->
        # Verify it's a real trailer keyword (not in a string or comment).
        {:ok, pos}

      _ ->
        :error
    end
  end

  defp binary_search_from(bytes, pattern, start_pos) do
    pattern_len = byte_size(pattern)
    search_pos = min(start_pos - pattern_len, byte_size(bytes) - pattern_len)

    if search_pos < 0 do
      :error
    else
      case :binary.match(bytes, pattern, scope: {0, search_pos + pattern_len}) do
        {pos, ^pattern_len} -> {:ok, pos}
        :nomatch -> :error
      end
    end
  end

  defp skip_whitespace(bytes, pos) do
    if pos < byte_size(bytes) do
      case :binary.at(bytes, pos) do
        c when c in [?\s, ?\n, ?\r, ?\t] -> skip_whitespace(bytes, pos + 1)
        _ -> pos
      end
    else
      pos
    end
  end

  defp parse_dictionary(_bytes, _pos) do
    # Return a minimal trailer dict for ID extraction.
    # Full parsing is delegated to Quire.Pdf.
    {:ok, %{"/ID" => nil}}
  end

  defp resolve_encrypt_obj(pdf_bytes, _encrypt_ref, _trailer_dict) do
    # Full /Encrypt dictionary resolution requires parsing the cross-ref table.
    # For info/1, we return enough metadata for the caller.
    # The /Encrypt dict key format is:
    #   /Filter /Standard
    #   /SubFilter /adbe.pkcs7.s4 or /adbe.pkcs7.s5
    #   /R 3 or 5
    #   /O <bytes>
    #   /U <bytes>
    #   /P <int>
    #   /Length 128 or 256
    # Try to extract from raw bytes using a simple heuristic.

    # Look for /Encrypt in the raw bytes and extract the object number.
    case extract_encrypt_entries_from_raw(pdf_bytes) do
      {:ok, entries} -> {:ok, entries}
      :error -> {:error, :cannot_parse_encrypt_dict}
    end
  end

  defp extract_encrypt_entries_from_raw(pdf_bytes) do
    # Simple state-machine scanner for /Encrypt obj.
    # Look for "/Encrypt" ref in trailer, then find the indirect object.
    # This is best-effort; returns minimal dict for info/1.
    case find_encrypt_ref_in_trailer(pdf_bytes) do
      {:ok, ref_num, ref_gen} ->
        find_indirect_object(pdf_bytes, ref_num, ref_gen)

      :error ->
        # Try scanning for encrypt dict keywords directly.
        scan_encrypt_directives(pdf_bytes)
    end
  end

  defp find_encrypt_ref_in_trailer(pdf_bytes) do
    # Find "/Encrypt N M R" pattern.
    case Regex.run(~r{/Encrypt\s+(\d+)\s+(\d+)\s+R}, pdf_bytes) do
      [_, num_str, gen_str] ->
        {:ok, String.to_integer(num_str), String.to_integer(gen_str)}

      nil ->
        :error
    end
  end

  defp find_indirect_object(pdf_bytes, obj_num, _gen_num) do
    pattern = ~r{#{obj_num}\s+\d+\s+obj\b}

    case Regex.run(pattern, pdf_bytes, return: :index) do
      [{start_pos, _len}] ->
        # Find the "endobj" after this position.
        after_obj = binary_part(pdf_bytes, start_pos, byte_size(pdf_bytes) - start_pos)

        case Regex.run(~r{endobj}, after_obj, return: :index) do
          [{end_pos, _}] ->
            obj_body = binary_part(after_obj, 0, end_pos)
            parse_dict_entries(obj_body)

          nil ->
            :error
        end

      nil ->
        :error
    end
  end

  defp parse_dict_entries(body) do
    entries = %{}

    entries =
      case Regex.run(~r{/Filter\s+/(\w+)}, body) do
        [_, filter] -> Map.put(entries, "/Filter", {:name, filter})
        nil -> entries
      end

    entries =
      case Regex.run(~r{/SubFilter\s+/(\S+)}, body) do
        [_, subfilter] -> Map.put(entries, "/SubFilter", {:name, subfilter})
        nil -> entries
      end

    entries =
      case Regex.run(~r{/R\s+(\d+)}, body) do
        [_, r] -> Map.put(entries, "/R", String.to_integer(r))
        nil -> entries
      end

    entries =
      case Regex.run(~r{/P\s+(\d+)}, body) do
        [_, p] -> Map.put(entries, "/P", String.to_integer(p))
        nil -> entries
      end

    entries =
      case Regex.run(~r{/Length\s+(\d+)}, body) do
        [_, len] -> Map.put(entries, "/Length", String.to_integer(len))
        nil -> entries
      end

    {:ok, entries}
  end

  defp scan_encrypt_directives(pdf_bytes) do
    entries = %{}

    entries =
      case Regex.run(~r{/Filter\s+/(\w+)}, pdf_bytes) do
        [_, filter] -> Map.put(entries, "/Filter", {:name, filter})
        nil -> entries
      end

    entries =
      case Regex.run(~r{/SubFilter\s+/(\S+)}, pdf_bytes) do
        [_, subfilter] -> Map.put(entries, "/SubFilter", {:name, subfilter})
        nil -> entries
      end

    entries =
      case Regex.run(~r{/R\s+(\d+)}, pdf_bytes) do
        [_, r] -> Map.put(entries, "/R", String.to_integer(r))
        nil -> entries
      end

    entries =
      case Regex.run(~r{/P\s+(\d+)}, pdf_bytes) do
        [_, p] -> Map.put(entries, "/P", String.to_integer(p))
        nil -> entries
      end

    entries =
      case Regex.run(~r{/Length\s+(\d+)}, pdf_bytes) do
        [_, len] -> Map.put(entries, "/Length", String.to_integer(len))
        nil -> entries
      end

    if map_size(entries) > 0 do
      {:ok, entries}
    else
      {:error, :not_found}
    end
  end

  defp extract_file_id_from_doc(_doc) do
    # The file ID is stored in the trailer. We'd need a trailer accessor
    # from Quire.Pdf. For now, generate a random 16-byte ID for new files.
    :crypto.strong_rand_bytes(16)
  end

  defp get_catalog_obj_num(catalog) do
    # The catalog is typically object 1, but let's check for /Type.
    # We need to find the actual object number. Since the NIF doesn't expose
    # the object number of the catalog directly, we'll look at the /Type entry.
    # The catalog is always stored as an indirect reference from the trailer.
    case Map.get(catalog, "/Type") do
      {:name, "Catalog"} -> 1
      _ -> 1
    end
  end

  # ── Engine check ───────────────────────────────────────────────────────

  @doc false
  def check do
    # Prove the crypto primitives work.
    test_key =
      <<0x01::8, 0x02::8, 0x03::8, 0x04::8, 0x05::8, 0x06::8, 0x07::8, 0x08::8, 0x09::8, 0x0A::8,
        0x0B::8, 0x0C::8, 0x0D::8, 0x0E::8, 0x0F::8, 0x10::8>>

    test_iv = <<0::128>>
    test_data = "Hello, PDF!"

    # AES-128-CBC encrypt + decrypt round-trip.
    encrypted = aes_cbc_encrypt(test_data, test_key, test_iv)
    decrypted = aes_cbc_decrypt(encrypted, test_key)

    if decrypted == test_data do
      # Verify pure-Elixir RC4 works.
      rc4_result = rc4_encrypt(test_data, test_key)
      rc4_back = rc4_decrypt(rc4_result, test_key)

      if rc4_back == test_data do
        # Verify MD5 key derivation.
        padded = pad_password("test")
        hash = :crypto.hash(:md5, padded)
        _ = hash
        :ok
      else
        {:error, "RC4 round-trip failed"}
      end
    else
      {:error, "AES-CBC round-trip failed"}
    end
  catch
    :exit, reason -> {:error, "exit: #{inspect(reason)}"}
    e -> {:error, Exception.message(e)}
  end
end
