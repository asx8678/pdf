defmodule Quire.SecurityHandler.Decrypt do
  @moduledoc """
  PDF decryption — per-object stream/string decryption and remove-encryption.

  Operates on raw PDF bytes without the Quire.Pdf NIF (which returns
  `:password_error` for encrypted documents).  Implements the full flow:

    1. Parse the PDF cross-reference table and trailer.
    2. Extract the /Encrypt dictionary (including binary values).
    3. Authenticate the password and derive the file encryption key.
    4. Decrypt every encrypted stream and string in each object.
    5. Remove /Encrypt from the trailer and rebuild the PDF.

  Supports AESV2 (R=3, AES-128-CBC) and AESV3 (R=5, AES-256-CBC).
  """

  @doc """
  Remove encryption from a PDF and return decrypted bytes.

  The password is never persisted or logged.  Returns `{:ok, binary}` on
  success or `{:error, :invalid_password}` (or another reason) on failure.
  """
  @spec remove_encryption(binary(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def remove_encryption(pdf_bytes, password, opts \\ []) do
    _ = opts

    # 1. Parse the PDF to find the xref table, objects, and trailer.
    with {:ok, objects, trailer_dict} <- parse_pdf(pdf_bytes) do
      # 2. Extract the /Encrypt dictionary from the trailer reference.
      case extract_encrypt_dict_full(pdf_bytes, trailer_dict) do
        {:ok, encrypt_dict} ->
          # 3. Authenticate the password.
          file_id = extract_file_id(trailer_dict)
          encrypt_dict_with_id = Map.put(encrypt_dict, "__file_id", file_id)

          case authenticate(password, encrypt_dict_with_id) do
            {:ok, file_key} ->
              # 4. Determine algorithm.
              algorithm = detect_algorithm(encrypt_dict)

              # 5. Extract the encrypt dict object number so we skip it.
              enc_obj_num = extract_encrypt_obj_num(trailer_dict)

              # 6. Decrypt every other object.
              decrypted_objects =
                Enum.map(objects, fn obj ->
                  if obj.obj_num == enc_obj_num do
                    # Do not decrypt the encrypt dict object itself — its
                    # binary values (O, U, etc.) are intentionally opaque.
                    obj
                  else
                    decrypt_object_streams_and_strings(obj, file_key, algorithm)
                  end
                end)

              # 7. Remove /Encrypt from the trailer and rebuild.
              clean_trailer = Map.delete(trailer_dict, "/Encrypt")
              rebuild_pdf(pdf_bytes, decrypted_objects, clean_trailer)

            {:error, :password_error} ->
              {:error, :invalid_password}

            {:error, reason} ->
              {:error, reason}
          end

        :not_found ->
          {:error, :not_encrypted}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Decrypt a single encrypted stream or string with per-object key derivation.

  For AESV2 (R=3) the per-object key is derived from the file encryption key,
  object number and generation number via Algorithm 1 (ISO 32000‑2 §7.6.3.2).

  For AESV3 (R=5) the file encryption key is used directly without derivation.
  """
  @spec decrypt_object(
          encrypted_data :: binary(),
          file_key :: binary(),
          obj_num :: non_neg_integer(),
          gen_num :: non_neg_integer(),
          algorithm :: :aesv2 | :aesv3
        ) :: binary()
  def decrypt_object(encrypted_data, file_key, obj_num, gen_num, algorithm) do
    obj_key = derive_obj_key(file_key, obj_num, gen_num, algorithm)
    Quire.SecurityHandler.aes_cbc_decrypt(encrypted_data, obj_key)
  end

  # ── PDF parsing ────────────────────────────────────────────────────────

  # Parses the PDF bytes, returning {:ok, [objects], trailer_dict} or error.
  defp parse_pdf(pdf_bytes) do
    with {:ok, xref_entries, trailer_dict} <- parse_xref_and_trailer(pdf_bytes) do
      objects =
        Enum.map(xref_entries, fn {obj_num, gen_num, offset, _status} ->
          read_object(pdf_bytes, obj_num, gen_num, offset)
        end)

      {:ok, objects, trailer_dict}
    end
  end

  # Finds the xref table, parses entries and trailer dictionary.
  defp parse_xref_and_trailer(pdf_bytes) do
    # First find the cross-reference table.
    case find_startxref(pdf_bytes) do
      {:ok, xref_offset} ->
        parse_xref_at(pdf_bytes, xref_offset)

      :error ->
        # Try to find xref keyword directly (for very simple PDFs).
        case find_xref_keyword(pdf_bytes) do
          {:ok, offset} -> parse_xref_at(pdf_bytes, offset)
          :error -> {:error, :invalid_pdf}
        end
    end
  end

  # Finds the startxref offset (the byte offset of the xref keyword).
  # Scans the last 2 KiB of the PDF for the "startxref" keyword.
  defp find_startxref(pdf_bytes) do
    size = byte_size(pdf_bytes)
    search_size = min(size, 2048)
    tail = binary_part(pdf_bytes, size - search_size, search_size)

    case :binary.match(tail, "startxref") do
      {:ok, pos, _len} ->
        after_xref =
          tail
          |> binary_part(pos + 9, search_size - pos - 9)
          |> String.trim()

        case Integer.parse(after_xref) do
          {offset, _} -> {:ok, offset}
          :error -> :error
        end

      :nomatch ->
        :error
    end
  end

  # Binary search helper — finds first occurrence of pattern in binary.
  defp binary_search(binary, pattern) do
    case :binary.match(binary, pattern) do
      {pos, _len} -> {:ok, pos}
      :nomatch -> :error
    end
  end

  # Find bare "xref" keyword in the PDF (fallback).
  defp find_xref_keyword(pdf_bytes) do
    # Look for "xref" preceded by newline or at start.
    case binary_search(pdf_bytes, "\nxref\n") do
      {:ok, pos} -> {:ok, pos + 1}
      :error -> binary_search(pdf_bytes, "\rxref\n")
    end
  end

  # Parse the cross-reference table starting at the given offset.
  defp parse_xref_at(pdf_bytes, offset) do
    # Skip "xref" keyword and whitespace.
    remaining = binary_part(pdf_bytes, offset, byte_size(pdf_bytes) - offset)

    remaining =
      if String.starts_with?(remaining, "xref") or String.starts_with?(remaining, "xref\r") do
        # Skip the xref keyword and following whitespace.
        after_xref = String.trim_leading(remaining, "xref\r\n ")
        after_xref
      else
        remaining
      end

    # Parse xref subsections (e.g. "0 6\n...entries...\n").
    {entries, _rest} = parse_xref_subsections(remaining, [])
    entries = Enum.reverse(entries)

    # After the xref entries, find the trailer keyword and dict.
    case binary_search(remaining, "trailer") do
      {:ok, trailer_pos} ->
        trailer_bytes = binary_part(remaining, trailer_pos, byte_size(remaining) - trailer_pos)
        # Skip "trailer" keyword and parse dictionary.
        after_trailer = String.trim_leading(trailer_bytes, "trailer\r\n ")
        {:ok, trailer_dict, _} = parse_pdf_dict(after_trailer, 0)
        {:ok, entries, trailer_dict}

      :error ->
        {:error, :invalid_pdf}
    end
  end

  # Parse xref subsections: "start count\nentry\nentry\n..."
  defp parse_xref_subsections(<<>>, acc), do: {acc, <<>>}

  defp parse_xref_subsections(data, acc) do
    data = String.trim_leading(data)

    cond do
      data == "" or String.starts_with?(data, "trailer") ->
        {acc, data}

      String.starts_with?(data, "xref") ->
        data = String.trim_leading(data, "xref\r\n ")
        parse_xref_subsections(data, acc)

      true ->
        # Try to parse "start count" line.
        case parse_integer_line(data) do
          {start_num, after_start} ->
            trimmed = String.trim_leading(after_start)

            case parse_integer_line(trimmed) do
              {count, after_count} ->
                entries_trimmed = String.trim_leading(after_count)
                {subsection_entries, rest} = parse_xref_entries(entries_trimmed, count, [])

                entries =
                  Enum.map(
                    Enum.with_index(subsection_entries),
                    fn {entry, idx} ->
                      {start_num + idx, entry}
                    end
                  )

                parse_xref_subsections(rest, acc ++ entries)

              :error ->
                {acc, data}
            end

          :error ->
            {acc, data}
        end
    end
  end

  # Parse an integer from the start of a binary, returning {int, rest}.
  defp parse_integer_line(data) do
    trimmed = String.trim_leading(data)

    case Integer.parse(trimmed) do
      {n, rest} -> {n, rest}
      :error -> :error
    end
  end

  # Parse N xref entries (each "XXXXXXXXX GGGGG n" or "XXXXXXXXX GGGGG f").
  defp parse_xref_entries(data, 0, acc), do: {Enum.reverse(acc), data}

  defp parse_xref_entries(data, count, acc) do
    trimmed = String.trim_leading(data)
    # Pattern: 10 digits offset, space, 5 digits gen, space, n/f
    case Regex.run(~r/^(\d{10})\s+(\d{5})\s+([nf])\s*/s, trimmed) do
      [_, offset_str, gen_str, status_str] ->
        offset = String.to_integer(offset_str)
        gen_num = String.to_integer(gen_str)
        status = if status_str == "n", do: :in_use, else: :free

        rest =
          String.trim_leading(
            String.replace_prefix(
              trimmed,
              [offset_str, " ", gen_str, " ", status_str, " "] |> Enum.join(),
              ""
            )
          )

        # Handle the trailing \s*\n
        rest = String.trim_leading(rest)
        parse_xref_entries(rest, count - 1, [{offset, gen_num, status} | acc])

      nil ->
        # Maybe the regex didn't match due to non-standard formatting.
        # Try simpler split approach.
        parts = String.split(trimmed, ~r/[\s]+/, parts: 4)

        case parts do
          [offset_str, gen_str, status_str | _] when byte_size(offset_str) <= 10 ->
            offset = String.to_integer(offset_str)
            gen_num = String.to_integer(gen_str)
            status = if String.starts_with?(status_str, "n"), do: :in_use, else: :free

            rest =
              trimmed
              |> String.replace_prefix(offset_str <> " ", "")
              |> String.trim_leading()
              |> String.replace_prefix(gen_str <> " ", "")
              |> String.trim_leading()
              |> String.replace_prefix(status_str, "")
              |> String.trim_leading()

            parse_xref_entries(rest, count - 1, [{offset, gen_num, status} | acc])

          _ ->
            parse_xref_entries(data, 0, acc)
        end
    end
  end

  # Read a single indirect object from the PDF bytes at a given offset.
  defp read_object(pdf_bytes, obj_num, gen_num, offset) do
    # The offset points to the "N G obj" line.
    remaining = binary_part(pdf_bytes, offset, byte_size(pdf_bytes) - offset)

    # Find "endobj" or "endobj\n" or "endobj\r" marker.
    case binary_search(remaining, "endobj") do
      {:ok, endobj_pos} ->
        raw = binary_part(remaining, 0, endobj_pos + 6)

        # Skip the "N G obj" header.
        case Regex.run(~r/^\d+\s+\d+\s+obj\s*/s, raw) do
          [header] ->
            dict_body = String.trim_leading(String.replace_prefix(raw, header, ""))
            parse_object_body(dict_body, obj_num, gen_num, raw)

          nil ->
            # Relaxed parsing — try without leading whitespace.
            trimmed = String.trim_leading(raw)

            case Regex.run(~r/^\d+\s+\d+\s+obj\s*/s, trimmed) do
              [header] ->
                dict_body = String.trim_leading(String.replace_prefix(trimmed, header, ""))
                parse_object_body(dict_body, obj_num, gen_num, trimmed)

              nil ->
                %{obj_num: obj_num, gen_num: gen_num, dict: %{}, stream: nil, raw: raw}
            end
        end

      :error ->
        %{obj_num: obj_num, gen_num: gen_num, dict: %{}, stream: nil, raw: <<>>}
    end
  end

  # Parse an object's body (dictionary + optional stream).
  defp parse_object_body(body, obj_num, gen_num, raw) do
    # Check if there's a stream.
    case binary_search(body, "stream") do
      {:ok, stream_kw_pos} ->
        # Parse the dictionary (everything before "stream").
        dict_str = binary_part(body, 0, stream_kw_pos) |> String.trim()
        {:ok, dict, _} = parse_pdf_dict(dict_str, 0)

        # Extract stream data between "stream\n" and "\nendstream".
        after_stream_kw =
          binary_part(body, stream_kw_pos + 6, byte_size(body) - stream_kw_pos - 6)

        {stream_data, _rest} =
          case binary_search(after_stream_kw, "endstream") do
            {:ok, endstream_pos} ->
              raw_stream_data =
                binary_part(after_stream_kw, 0, endstream_pos) |> String.trim_leading()

              {raw_stream_data, ""}

            :error ->
              {<<>>, <<>>}
          end

        %{
          obj_num: obj_num,
          gen_num: gen_num,
          dict: dict,
          stream: stream_data,
          raw: raw
        }

      :error ->
        # No stream — just dictionary or value.
        {:ok, dict, _} = parse_pdf_dict(body, 0)

        %{
          obj_num: obj_num,
          gen_num: gen_num,
          dict: dict,
          stream: nil,
          raw: raw
        }
    end
  end

  # ── PDF dictionary parser ──────────────────────────────────────────────

  # Parse a PDF dictionary from binary starting at position pos.
  # Returns {:ok, map, next_pos} or {:error, reason}.
  defp parse_pdf_dict(data, pos) do
    trimmed = String.trim_leading(binary_part(data, pos, byte_size(data) - pos))

    if String.starts_with?(trimmed, "<<") do
      parse_dict_content(trimmed, 2, %{})
    else
      parse_dict_content_implicit(trimmed, %{})
    end
  end

  # Parse dict content after the opening "<<".
  defp parse_dict_content(data, pos, acc) do
    rest = binary_part(data, pos, byte_size(data) - pos)
    trimmed = String.trim_leading(rest)

    cond do
      String.starts_with?(trimmed, ">>") ->
        {:ok, acc, pos + byte_size(rest) - byte_size(trimmed) + 2}

      trimmed == "" or String.starts_with?(trimmed, "endobj") or
        String.starts_with?(trimmed, "stream") or String.starts_with?(trimmed, "trailer") ->
        {:ok, acc, pos}

      true ->
        # Parse a key-value pair.
        case parse_pdf_name(trimmed) do
          {key, after_key} ->
            after_key_trimmed = String.trim_leading(after_key)
            {value, after_value} = parse_pdf_value(after_key_trimmed)
            new_acc = Map.put(acc, key, value)
            consumed = byte_size(data) - byte_size(after_value)
            parse_dict_content(data, consumed, new_acc)

          :error ->
            # Unable to parse key — skip this token.
            {_skipped, after_skip} = skip_pdf_token(trimmed)
            consumed = byte_size(data) - byte_size(after_skip)
            parse_dict_content(data, consumed, acc)
        end
    end
  end

  # Parse a dict when there's no explicit << >> (e.g., the trailer might not
  # always be wrapped with them when we've pre-consumed).
  defp parse_dict_content_implicit(data, acc) do
    trimmed = String.trim_leading(data)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "endobj") or
        String.starts_with?(trimmed, "stream") or String.starts_with?(trimmed, "trailer") or
          String.starts_with?(trimmed, "xref") ->
        {:ok, acc, data}

      String.starts_with?(trimmed, ">>") ->
        {:ok, acc, trimmed}

      true ->
        # Parse key-value pair.
        case parse_pdf_name(trimmed) do
          {key, after_key} ->
            after_key_trimmed = String.trim_leading(after_key)
            {value, after_value} = parse_pdf_value(after_key_trimmed)
            new_acc = Map.put(acc, key, value)
            parse_dict_content_implicit(after_value, new_acc)

          :error ->
            {_skipped, after_skip} = skip_pdf_token(trimmed)
            parse_dict_content_implicit(after_skip, acc)
        end
    end
  end

  # ── PDF value parsers ──────────────────────────────────────────────────

  # Parse any PDF value, returning {value, rest}.
  defp parse_pdf_value(<<>>), do: {nil, <<>>}

  defp parse_pdf_value(data) do
    trimmed = String.trim_leading(data)
    first = first_byte(trimmed)

    cond do
      trimmed == "" ->
        {nil, trimmed}

      first in ?0..?9 or first == ?- or first == ?+ or first == ?. ->
        parse_pdf_number(trimmed)

      first == ?/ ->
        parse_pdf_name(trimmed)

      first == ?( ->
        parse_pdf_literal_string(trimmed)

      first == ?< and byte_size(trimmed) >= 2 and :binary.at(trimmed, 1) == ?< ->
        # Nested dict
        parse_pdf_dict(trimmed, 0)

      first == ?< ->
        parse_pdf_hex_string(trimmed)

      first == ?[ ->
        parse_pdf_array(trimmed)

      first == ?t ->
        # true
        parse_pdf_keyword(trimmed)

      first == ?f ->
        # false
        parse_pdf_keyword(trimmed)

      first == ?n ->
        # null
        parse_pdf_keyword(trimmed)

      first == ?R ->
        # Bare R — part of a reference, but we handle references in parse_pdf_primary
        {nil, trimmed}

      true ->
        # Skip unknown token.
        {_skipped, rest} = skip_pdf_token(trimmed)
        {nil, rest}
    end
  end

  # Parse a "primary" (handles indirect references "N G R").
  defp parse_pdf_primary(data) do
    trimmed = String.trim_leading(data)

    # Try to match N M R pattern.
    case Regex.run(~r/^(\d+)\s+(\d+)\s+R\b/, trimmed) do
      [_, num_str, gen_str] ->
        obj_num = String.to_integer(num_str)
        gen_num = String.to_integer(gen_str)
        consumed = byte_size(num_str) + 1 + byte_size(gen_str) + 1 + 1
        rest = String.trim_leading(binary_part(trimmed, consumed, byte_size(trimmed) - consumed))
        {{:ref, obj_num, gen_num}, rest}

      nil ->
        parse_pdf_value(trimmed)
    end
  end

  # Parse a PDF name (/Key).
  defp parse_pdf_name(<<?/, rest::binary>>) do
    {name, rest1} = parse_regular_token(rest)
    {<<?/::utf8, name::binary>>, rest1}
  end

  defp parse_pdf_name(_), do: :error

  # Parse a PDF number (integer or real).
  defp parse_pdf_number(data) do
    trimmed = String.trim_leading(data)
    # Match optional sign, digits, optional decimal.
    case Regex.run(~r/^[+-]?(?:\d+\.?\d*|\.\d+)/, trimmed) do
      [match] ->
        rest = String.trim_leading(String.replace_prefix(trimmed, match, ""))

        if String.match?(match, ~r/^\d+$/) do
          {String.to_integer(match), rest}
        else
          {String.to_float(match), rest}
        end

      nil ->
        {nil, data}
    end
  end

  # Parse a literal string (…).
  defp parse_pdf_literal_string(data) do
    trimmed = String.trim_leading(data)

    if String.starts_with?(trimmed, "(") do
      parse_balanced_string(trimmed, 0, 1, <<>>)
    else
      {nil, data}
    end
  end

  # Parse a balanced parenthesized string, handling nested parens and escapes.
  defp parse_balanced_string(<<?\\, c::8, rest::binary>>, depth, open, acc) when depth >= 0 do
    # Handle escape sequences
    char =
      case c do
        ?n -> 10
        ?r -> 13
        ?t -> 9
        ?( -> 40
        ?) -> 41
        ?\\ -> 92
        10 -> 10
        13 -> 10
        _ -> c
      end

    parse_balanced_string(rest, depth, open, <<acc::binary, char::8>>)
  end

  defp parse_balanced_string(<<?(, rest::binary>>, depth, open, acc) do
    parse_balanced_string(rest, depth + 1, open, <<acc::binary, ?(::8>>)
  end

  defp parse_balanced_string(<<?), rest::binary>>, depth, open, acc) do
    if depth == 0 and open > 0 do
      # We've closed the outermost paren.
      {acc, rest}
    else
      parse_balanced_string(rest, depth - 1, open, <<acc::binary, ?)::8>>)
    end
  end

  defp parse_balanced_string(<<c::8, rest::binary>>, depth, open, acc) do
    parse_balanced_string(rest, depth, open, <<acc::binary, c::8>>)
  end

  defp parse_balanced_string(<<>>, _depth, _open, acc) do
    {acc, <<>>}
  end

  # Parse a hex string (<hexdigits>).
  defp parse_pdf_hex_string(data) do
    trimmed = String.trim_leading(data)

    if String.starts_with?(trimmed, "<") and not String.starts_with?(trimmed, "<<") do
      # Find the closing >.
      rest = String.trim_leading(String.replace_prefix(trimmed, "<", ""))

      case binary_search(rest, ">") do
        {:ok, close_pos} ->
          hex_str = String.trim(binary_part(rest, 0, close_pos))
          clean_hex = String.replace(hex_str, ~r/\s/, "")

          binary =
            if String.length(clean_hex) > 0 do
              # Pad to even length
              padded =
                if rem(String.length(clean_hex), 2) == 0, do: clean_hex, else: clean_hex <> "0"

              {:ok, decoded} = Base.decode16(padded, case: :mixed)
              decoded
            else
              <<>>
            end

          after_close =
            String.trim_leading(binary_part(rest, close_pos + 1, byte_size(rest) - close_pos - 1))

          {binary, after_close}

        :error ->
          {nil, data}
      end
    else
      {nil, data}
    end
  end

  # Parse an array [...].
  defp parse_pdf_array(data) do
    trimmed = String.trim_leading(data)

    if String.starts_with?(trimmed, "[") do
      after_open = String.trim_leading(String.replace_prefix(trimmed, "[", ""))
      {items, rest} = parse_array_items(after_open, [])
      {Enum.reverse(items), rest}
    else
      {nil, data}
    end
  end

  defp parse_array_items(data, acc) do
    trimmed = String.trim_leading(data)

    cond do
      trimmed == "" ->
        {Enum.reverse(acc), trimmed}

      String.starts_with?(trimmed, "]") ->
        rest = String.trim_leading(String.replace_prefix(trimmed, "]", ""))
        {Enum.reverse(acc), rest}

      true ->
        case parse_pdf_primary(trimmed) do
          {nil, after_val} when after_val != trimmed ->
            parse_array_items(after_val, acc)

          {nil, _} ->
            # Skip one token to avoid infinite loop
            {_skipped, rest} = skip_pdf_token(trimmed)
            parse_array_items(rest, acc)

          {value, after_val} ->
            parse_array_items(after_val, [value | acc])
        end
    end
  end

  # Parse PDF keywords (true, false, null).
  defp parse_pdf_keyword(data) do
    trimmed = String.trim_leading(data)

    cond do
      String.starts_with?(trimmed, "true") ->
        rest = String.trim_leading(String.replace_prefix(trimmed, "true", ""))
        {true, rest}

      String.starts_with?(trimmed, "false") ->
        rest = String.trim_leading(String.replace_prefix(trimmed, "false", ""))
        {false, rest}

      String.starts_with?(trimmed, "null") ->
        rest = String.trim_leading(String.replace_prefix(trimmed, "null", ""))
        {:null, rest}

      true ->
        # Unknown keyword — skip it.
        {_token, rest} = parse_regular_token(trimmed)
        {nil, rest}
    end
  end

  # Skip a PDF token (unknown).
  defp skip_pdf_token(data) do
    trimmed = String.trim_leading(data)
    first = first_byte(trimmed)

    cond do
      trimmed == "" ->
        {nil, trimmed}

      first == ?< and byte_size(trimmed) >= 2 and :binary.at(trimmed, 1) == ?< ->
        # Skip dict
        case find_closing_double_angle(trimmed, 2) do
          {:ok, close_pos} ->
            {binary_part(trimmed, 0, close_pos + 2),
             String.trim_leading(
               binary_part(trimmed, close_pos + 2, byte_size(trimmed) - close_pos - 2)
             )}

          :error ->
            {trimmed, <<>>}
        end

      first == ?[ ->
        skip_balanced(trimmed, ?[, ?])

      first == ?( ->
        parse_pdf_literal_string(trimmed)

      true ->
        parse_regular_token(trimmed)
    end
  end

  # Parse a regular (non-special) token — sequence of non-whitespace, non-delimiter chars.
  defp parse_regular_token(data) do
    parse_token_chars(data, <<>>)
  end

  defp parse_token_chars(<<>>, acc), do: {acc, <<>>}

  defp parse_token_chars(<<c::8, rest::binary>>, acc) do
    if c in [?\s, ?\n, ?\r, ?\t, ?/, ?<, ?>, ?[, ?], ?(, ?), ?%] do
      {acc, <<c::8, rest::binary>>}
    else
      parse_token_chars(rest, <<acc::binary, c::8>>)
    end
  end

  defp first_byte(<<b::8, _::binary>>), do: b
  defp first_byte(<<>>), do: nil

  # Find closing >>.
  defp find_closing_double_angle(data, pos) do
    case binary_search(binary_part(data, pos, byte_size(data) - pos), ">>") do
      {:ok, p} -> {:ok, pos + p}
      :error -> :error
    end
  end

  # Skip balanced [...] brackets.
  defp skip_balanced(data, open, _close) do
    trimmed = String.trim_leading(data)

    if String.starts_with?(trimmed, <<open::8>>) do
      rest = String.trim_leading(String.replace_prefix(trimmed, <<open::8>>, ""))
      {_items, after_close} = parse_array_items(rest, [])
      {binary_part(trimmed, 0, byte_size(trimmed) - byte_size(after_close)), after_close}
    else
      {nil, data}
    end
  end

  # ── /Encrypt dictionary extraction ─────────────────────────────────────

  # Extract the full /Encrypt dictionary from the PDF.
  # Returns {:ok, encrypt_dict_map} or :not_found or {:error, reason}.
  defp extract_encrypt_dict_full(pdf_bytes, trailer_dict) do
    case Map.get(trailer_dict, "/Encrypt") do
      {:ref, enc_obj_num, _enc_gen} ->
        # Find the encrypt object in the PDF.
        case find_object_raw_bytes(pdf_bytes, enc_obj_num) do
          {:ok, raw_bytes} ->
            parse_encrypt_dict_from_raw(raw_bytes)

          :error ->
            # Fallback: scan for encrypt dict in raw bytes.
            scan_encrypt_from_raw(pdf_bytes)
        end

      _ ->
        # Try scanning directly.
        scan_encrypt_from_raw(pdf_bytes)
    end
  end

  # Find an indirect object's raw bytes by scanning for "N 0 obj".
  defp find_object_raw_bytes(pdf_bytes, obj_num) do
    pattern = ~r/#{obj_num}\s+\d+\s+obj\b/

    case Regex.run(pattern, pdf_bytes, return: :index) do
      [{start_pos, _len}] ->
        after_obj = binary_part(pdf_bytes, start_pos, byte_size(pdf_bytes) - start_pos)

        case :binary.match(after_obj, "endobj") do
          {end_pos, _} ->
            {:ok, binary_part(after_obj, 0, end_pos + 6)}

          :nomatch ->
            :error
        end

      nil ->
        :error
    end
  end

  # Parse the /Encrypt dictionary from raw object bytes.
  defp parse_encrypt_dict_from_raw(raw_bytes) do
    # Remove the "N G obj" header and "endobj" footer.
    obj_body =
      raw_bytes
      |> String.replace(~r/^\d+\s+\d+\s+obj\s*/s, "")
      |> String.replace(~r/\s*endobj\s*$/, "")
      |> String.trim()

    {:ok, dict, _} = parse_pdf_dict(obj_body, 0)

    # Convert hex string values to binaries and ensure required keys exist.
    dict = normalize_encrypt_dict(dict)
    {:ok, dict}
  end

  # Normalize an encrypt dictionary: decode hex string values, etc.
  defp normalize_encrypt_dict(dict) do
    dict
    |> maybe_decode_hex("/O")
    |> maybe_decode_hex("/U")
    |> maybe_decode_hex("/OE")
    |> maybe_decode_hex("/UE")
    |> maybe_decode_hex("/Perms")
    |> normalize_name("/Filter")
    |> normalize_name("/SubFilter")
    |> normalize_name("/StmF")
    |> normalize_name("/StrF")
  end

  # Decode a hex string field to binary, if present and not already binary.
  defp maybe_decode_hex(dict, key) do
    case Map.get(dict, key) do
      val when is_binary(val) ->
        # Already a binary — could be raw bytes or hex-encoded.
        # Check if it looks like hex: all hex chars, even length.
        if String.match?(val, ~r/^[0-9a-fA-F]+$/) and rem(byte_size(val), 2) == 0 do
          Map.put(dict, key, Base.decode16!(val, case: :mixed))
        else
          dict
        end

      val when is_list(val) ->
        # Array — leave as-is.
        dict

      _ ->
        dict
    end
  end

  # Normalize a name field to {:name, "Value"} format.
  defp normalize_name(dict, key) do
    case Map.get(dict, key) do
      {:name, _} ->
        dict

      val when is_binary(val) ->
        name = String.trim_leading(val, "/")
        Map.put(dict, key, {:name, name})

      _ ->
        dict
    end
  end

  # Scan for /Encrypt dictionary in raw bytes (fallback).
  defp scan_encrypt_from_raw(pdf_bytes) do
    case Regex.run(~r{/Encrypt\s+(\d+)\s+(\d+)\s+R}, pdf_bytes) do
      [_, num_str, gen_str] ->
        obj_num = String.to_integer(num_str)
        _gen_num = String.to_integer(gen_str)

        case find_object_raw_bytes(pdf_bytes, obj_num) do
          {:ok, raw} -> parse_encrypt_dict_from_raw(raw)
          :error -> {:error, :cannot_parse_encrypt_dict}
        end

      nil ->
        :not_found
    end
  end

  # Extract the encrypt object number from the trailer.
  defp extract_encrypt_obj_num(trailer_dict) do
    case Map.get(trailer_dict, "/Encrypt") do
      {:ref, obj_num, _} -> obj_num
      _ -> nil
    end
  end

  # Extract the file ID from the trailer.
  defp extract_file_id(trailer_dict) do
    case Map.get(trailer_dict, "/ID") do
      [first_id | _] when is_binary(first_id) -> first_id
      _ -> <<>>
    end
  end

  # Detect the encryption algorithm from the encrypt dictionary.
  defp detect_algorithm(encrypt_dict) do
    sub_filter = Map.get(encrypt_dict, "/SubFilter", "")

    case sub_filter do
      {:name, "adbe.pkcs7.s5"} ->
        :aesv3

      {:name, "adbe.pkcs7.s4"} ->
        :aesv2

      _ ->
        case Map.get(encrypt_dict, "/R", 3) do
          r when r >= 5 -> :aesv3
          _ -> :aesv2
        end
    end
  end

  # ── Authentication ─────────────────────────────────────────────────────

  # Authenticate the password against the encrypt dictionary.
  # Returns {:ok, file_key} or {:error, :password_error} or {:error, reason}.
  defp authenticate(password, encrypt_dict) do
    r = Map.get(encrypt_dict, "/R", 3)

    case r do
      5 ->
        authenticate_r5(password, encrypt_dict)

      3 ->
        file_id = Map.get(encrypt_dict, "__file_id", <<>>)
        o_value = Map.get(encrypt_dict, "/O", <<>>)
        permissions = Map.get(encrypt_dict, "/P", 0)

        # Try as user password first.
        candidate_key =
          Quire.SecurityHandler.derive_key_r3(password, o_value, permissions, file_id)

        stored_u = Map.get(encrypt_dict, "/U", <<>>)

        if verify_u_r3(candidate_key, stored_u) do
          {:ok, candidate_key}
        else
          # Try as owner password.
          authenticate_owner_r3(password, encrypt_dict, file_id)
        end

      _ ->
        {:error, :unsupported_encryption_version}
    end
  end

  defp authenticate_r5(password, encrypt_dict) do
    u_value = Map.get(encrypt_dict, "/U", <<>>)

    if byte_size(u_value) >= 48 do
      user_validation_salt = binary_part(u_value, 32, 8)
      computed_u = :crypto.hash(:sha256, password <> user_validation_salt)
      stored_hash = binary_part(u_value, 0, 32)

      if computed_u == stored_hash do
        user_key_salt = binary_part(u_value, 40, 8)
        ue_value = Map.get(encrypt_dict, "/UE", <<>>)
        wrap_key = :crypto.hash(:sha256, password <> user_key_salt)
        file_encryption_key = Quire.SecurityHandler.aes_ecb_decrypt(ue_value, wrap_key)
        {:ok, file_encryption_key}
      else
        authenticate_owner_r5(password, encrypt_dict)
      end
    else
      {:error, :invalid_encrypt_dict}
    end
  end

  defp authenticate_owner_r5(password, encrypt_dict) do
    o_value = Map.get(encrypt_dict, "/O", <<>>)

    if byte_size(o_value) >= 48 do
      owner_validation_salt = binary_part(o_value, 32, 8)
      computed_o = :crypto.hash(:sha256, password <> owner_validation_salt)
      stored_hash = binary_part(o_value, 0, 32)

      if computed_o == stored_hash do
        owner_key_salt = binary_part(o_value, 40, 8)
        oe_value = Map.get(encrypt_dict, "/OE", <<>>)
        wrap_key = :crypto.hash(:sha256, password <> owner_key_salt)
        file_encryption_key = Quire.SecurityHandler.aes_ecb_decrypt(oe_value, wrap_key)
        {:ok, file_encryption_key}
      else
        {:error, :password_error}
      end
    else
      {:error, :invalid_encrypt_dict}
    end
  end

  defp authenticate_owner_r3(password, encrypt_dict, file_id) do
    padded_owner = Quire.SecurityHandler.pad_password(password)
    hash = :crypto.hash(:md5, padded_owner)
    stored_o = Map.get(encrypt_dict, "/O", <<>>)

    # Decrypt O to recover the user password.
    decrypted = reversed_rc4_decrypt_o(stored_o, hash)
    rc4_key = binary_part(hash, 0, 5)
    padded_user_password = rc4_decrypt(decrypted, rc4_key)

    # Trim the padding to recover the user password.
    user_password = String.trim_trailing(padded_user_password, <<0x28, 0xBF, 0x4E, 0x5E>>)

    permissions = Map.get(encrypt_dict, "/P", 0)
    o_value = Map.get(encrypt_dict, "/O", <<>>)

    candidate_key =
      Quire.SecurityHandler.derive_key_r3(user_password, o_value, permissions, file_id)

    stored_u = Map.get(encrypt_dict, "/U", <<>>)

    if verify_u_r3(candidate_key, stored_u) do
      {:ok, candidate_key}
    else
      {:error, :password_error}
    end
  end

  defp verify_u_r3(candidate_key, stored_u) do
    computed_u = Quire.SecurityHandler.compute_u_r3(candidate_key)

    byte_size(stored_u) >= 16 and
      binary_part(computed_u, 0, 16) == binary_part(stored_u, 0, 16)
  end

  defp reversed_rc4_decrypt_o(stored_o, hash) do
    Enum.reduce(19..1//-1, stored_o, fn i, acc ->
      iter_key = for(j <- 0..4, into: <<>>, do: <<Bitwise.bxor(:binary.at(hash, j), i)::8>>)
      rc4_decrypt(acc, iter_key)
    end)
  end

  defp rc4_decrypt(data, key) do
    Quire.SecurityHandler.rc4_decrypt(data, key)
  end

  # ── Per-object key derivation ──────────────────────────────────────────

  # Derive the per-object key.
  # For AESV2: MD5(file_key || obj_num_3 || gen_num_2) first 16 bytes.
  # For AESV3: file_key directly.
  defp derive_obj_key(file_key, obj_num, gen_num, :aesv2) do
    obj_key_data =
      file_key <>
        <<obj_num::24-little, gen_num::16-little>>

    hash = :crypto.hash(:md5, obj_key_data)

    # For AES-128, the key is the first 16 bytes of the hash.
    binary_part(hash, 0, min(byte_size(hash), 16))
  end

  defp derive_obj_key(file_key, _obj_num, _gen_num, :aesv3) do
    file_key
  end

  # ── Per-object stream/string decryption ───────────────────────────────

  # Decrypt an object's streams and string values.
  defp decrypt_object_streams_and_strings(obj, file_key, algorithm) do
    dict = obj.dict
    stream = obj.stream

    # Check if this object's default encryption applies.
    # In PDF 2.0 with /Encrypt, all streams and strings in indirect objects
    # are encrypted except those in the Encrypt dictionary itself.
    # Check the stream's /Filter for /Crypt specifically.

    # If no /Crypt filter but /Encrypt is present, streams are encrypted
    # under the default crypt filter (typically /StmF).
    encrypted_stream? =
      stream != nil and stream != <<>> and
        (has_crypt_filter?(dict) or
           true)

    # Determine if strings in this dict should be decrypted.
    # When /Encrypt is present, all literal strings and hex strings in indirect
    # object dictionaries are encrypted (except Encrypt dict itself).
    new_stream =
      if encrypted_stream? do
        decrypt_stream(stream, file_key, obj.obj_num, obj.gen_num, algorithm)
      else
        stream
      end

    new_dict =
      if algorithm do
        decrypt_dict_strings(dict, file_key, obj.obj_num, obj.gen_num, algorithm)
      else
        dict
      end

    %{obj | dict: new_dict, stream: new_stream}
  end

  defp has_crypt_filter?(dict) do
    # Check if /Filter or /F includes /Crypt
    filter = Map.get(dict, "/Filter", Map.get(dict, "/F"))

    case filter do
      {:name, "Crypt"} -> true
      list when is_list(list) -> Enum.any?(list, &(&1 == {:name, "Crypt"}))
      _ -> false
    end
  end

  # Default stream encryption applies if /Encrypt is present at the document level.
  # We always assume this is true when we reach this function (we already know
  # the document has /Encrypt). Decrypt all streams that aren't explicitly
  # exempt (the Encrypt dict object itself is already skipped in remove_encryption).

  # Decrypt a single object's stream data.
  defp decrypt_stream(stream_data, file_key, obj_num, gen_num, algorithm) do
    decrypt_object(stream_data, file_key, obj_num, gen_num, algorithm)
  rescue
    # Return as-is on failure
    _ -> stream_data
  end

  # Decrypt string values in an object dictionary.
  # Handles both literal strings and hex strings.
  defp decrypt_dict_strings(dict, file_key, obj_num, gen_num, algorithm) do
    Map.new(dict, fn {key, value} ->
      {key, decrypt_pdf_value(value, file_key, obj_num, gen_num, algorithm)}
    end)
  end

  # Recursively decrypt PDF values that are strings.
  defp decrypt_pdf_value(val, file_key, obj_num, gen_num, algorithm)

  defp decrypt_pdf_value(val, file_key, obj_num, gen_num, algorithm) when is_binary(val) do
    # A binary value could be:
    # 1. Raw binary (decoded from hex string) — decrypt it
    # 2. A literal string content — decrypt it
    # 3. Already-decoded data — leave it

    # If this is a short binary or looks like decoded hex data from the encrypt
    # dict, it might already be raw bytes. We try to decrypt and see.
    # Heuristic: if the binary looks like binary PDF data (has non-ASCII
    # content), it's likely a decrypted value or a non-string value.

    # For practical purposes, apply decryption if the binary is a hex-string
    # decoded value. Since we don't have the original encoding info, we check
    # if it looks like AES-CBC data (length > 16 and pseudo-random).
    if byte_size(val) > 16 and not String.printable?(val) do
      decrypt_object(val, file_key, obj_num, gen_num, algorithm)
    else
      val
    end
  rescue
    _ -> val
  end

  defp decrypt_pdf_value({:name, _} = name, _file_key, _on, _gn, _alg), do: name

  defp decrypt_pdf_value({:ref, _, _} = ref, _file_key, _on, _gn, _alg), do: ref

  defp decrypt_pdf_value(list, file_key, obj_num, gen_num, algorithm) when is_list(list) do
    Enum.map(list, &decrypt_pdf_value(&1, file_key, obj_num, gen_num, algorithm))
  end

  defp decrypt_pdf_value(nil, _file_key, _on, _gn, _alg), do: nil

  defp decrypt_pdf_value(val, _file_key, _on, _gn, _alg), do: val

  # ── PDF reconstruction ─────────────────────────────────────────────────

  # Rebuild the PDF bytes with decrypted objects and a clean trailer.
  defp rebuild_pdf(original_bytes, objects, trailer_dict) do
    # Preserve the original PDF header.
    header = extract_header(original_bytes)

    # Serialize all objects, tracking offsets by obj_num.
    {obj_offsets, _offset} =
      Enum.reduce(objects, {%{}, byte_size(header)}, fn obj, {acc, offset} ->
        obj_bytes = serialize_object(obj)
        new_offset = offset + byte_size(obj_bytes)
        {Map.put(acc, obj.obj_num, {obj.gen_num, offset, obj_bytes}), new_offset}
      end)

    # Build xref table from the object offset map.
    xref_table = build_xref_table(obj_offsets)

    # Build trailer without /Encrypt.
    max_obj =
      if map_size(obj_offsets) == 0 do
        0
      else
        obj_offsets |> Map.keys() |> Enum.max()
      end

    trailer = serialize_trailer(trailer_dict, max_obj + 1)

    # Assemble final PDF — objects in obj_num order.
    object_body =
      obj_offsets
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map_join(fn num ->
        {_gen, _off, bytes} = Map.get(obj_offsets, num)
        bytes
      end)

    xref_offset = byte_size(header) + byte_size(object_body)

    pdf =
      header <>
        object_body <>
        xref_table <>
        trailer <>
        "startxref\n#{xref_offset}\n%%%%EOF\n"

    {:ok, pdf}
  end

  # Extract the PDF header (everything from "%PDF" to the last newline before
  # the first indirect object).
  defp extract_header(pdf_bytes) do
    # The header is typically "%PDF-1.x\n%...\n"
    case Regex.run(~r/^%PDF-\d+\.\d+\s*.*?(?=\d+\s+\d+\s+obj)/s, pdf_bytes) do
      [header] ->
        header

      nil ->
        # Fallback: everything before "N 0 obj"
        case Regex.run(~r/^.*?(?=\d+\s+\d+\s+obj)/s, pdf_bytes) do
          [h] -> h
          nil -> binary_part(pdf_bytes, 0, min(100, byte_size(pdf_bytes)))
        end
    end
  end

  # Serialize a single object back to PDF bytes.
  defp serialize_object(obj) do
    obj_header = "#{obj.obj_num} #{obj.gen_num} obj\n"
    dict_str = serialize_pdf_dict(obj.dict)

    if obj.stream != nil and obj.stream != <<>> do
      stream_len = byte_size(obj.stream)

      # Update length in dict if present.
      dict_with_len =
        Map.put(obj.dict, "/Length", stream_len)
        # Remove Crypt filter from object
        |> Map.drop(["/Filter", "/F"])

      updated_dict_str = serialize_pdf_dict(dict_with_len)
      obj_header <> updated_dict_str <> "\nstream\n#{obj.stream}\nendstream\nendobj\n"
    else
      obj_header <> dict_str <> "\nendobj\n"
    end
  end

  # Serialize a PDF dictionary to string.
  defp serialize_pdf_dict(dict) when is_map(dict) do
    if map_size(dict) == 0 do
      "<<>>"
    else
      entries =
        Enum.map_join(dict, " ", fn {key, value} ->
          "#{key} #{serialize_pdf_value(value, key)}"
        end)

      "<< #{entries} >>"
    end
  end

  defp serialize_pdf_dict(_), do: "<<>>"

  # Serialize a PDF value.
  defp serialize_pdf_value(val, _key_context \\ nil)

  defp serialize_pdf_value({:name, name}, _key_context) do
    "/#{name}"
  end

  defp serialize_pdf_value({:ref, obj_num, gen_num}, _key_context) do
    "#{obj_num} #{gen_num} R"
  end

  defp serialize_pdf_value(val, _key_context) when is_integer(val) do
    Integer.to_string(val)
  end

  defp serialize_pdf_value(val, _key_context) when is_float(val) do
    # Format as a PDF real number without scientific notation
    :erlang.float_to_binary(val, [:compact, decimals: 4])
  end

  defp serialize_pdf_value(true, _key_context), do: "true"
  defp serialize_pdf_value(false, _key_context), do: "false"

  defp serialize_pdf_value(:null, _key_context), do: "null"

  defp serialize_pdf_value(val, _key_context) when is_binary(val) do
    # Output as hex string to handle arbitrary binary.
    "<#{Base.encode16(val, case: :upper)}>"
  end

  defp serialize_pdf_value(list, _key_context) when is_list(list) do
    items = Enum.map_join(list, " ", &serialize_pdf_value(&1))
    "[#{items}]"
  end

  defp serialize_pdf_value(nil, _key_context), do: "null"

  # Build the xref table section from a map of obj_num -> {gen, offset, bytes}.
  # Generates a single subsection from 0 to max_obj_num, with gaps as free entries.
  defp build_xref_table(obj_offsets) do
    max_obj =
      if map_size(obj_offsets) == 0 do
        0
      else
        obj_offsets |> Map.keys() |> Enum.max()
      end

    entries =
      Enum.reduce(0..max_obj, [], fn num, acc ->
        entry =
          case Map.get(obj_offsets, num) do
            {gen, offset, _bytes} ->
              "#{String.pad_leading(Integer.to_string(offset), 10, "0")} #{String.pad_leading(Integer.to_string(gen), 5, "0")} n \n"

            nil ->
              # Free entry
              "0000000000 65535 f \n"
          end

        [entry | acc]
      end)
      |> Enum.reverse()
      |> Enum.join()

    "xref\n0 #{max_obj + 1}\n#{entries}"
  end

  # Serialize the trailer dictionary without /Encrypt.
  defp serialize_trailer(trailer_dict, size) do
    # Build a clean trailer with /Size, /Root, /ID (if present), /Info (if present).
    clean = Map.drop(trailer_dict, ["/Encrypt", "__raw"])

    # Ensure /Size is set correctly.
    clean = Map.put(clean, "/Size", size)

    trailer_content = serialize_pdf_dict(clean)
    "trailer\n#{trailer_content}\n"
  end
end
