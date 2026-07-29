defmodule Quire.Office.Reader.Rtf do
  @moduledoc """
  Reader for `.rtf` (Rich Text Format) files.

  Parses RTF text content with a custom character-by-character tokenizer and
  builds `Quire.Office.Layout` sections — a single `:page` section — with
  `:paragraph` blocks.

  ## Supported constructs

    * Text paragraphs (delimited by `\\par`)
    * Line breaks (`\\line` become newlines)
    * Tabs (`\\tab` become tab characters)
    * Hex-encoded characters (`\\'xx`)
    * Escaped special characters (`\\{`, `\\}`, `\\\\`)
    * Non-breaking space (`\\~`)
    * Soft hyphen (`\\_`)

  ## Unsupported (reported as notes)

    * Tables (`\\cell`, `\\row`, `\\trowd`, `\\intbl`)
    * Embedded images
    * Headers, footers
    * Footnotes, endnotes
    * Text formatting (bold, italic, font selection, colours)
    * Document metadata (author, date, etc.)
    * Unicode escape sequences (`\\uNNNN`)

  All unsupported control words are silently skipped.
  """

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  @doc """
  Parse an `.rtf` file from bytes.

  Returns `{:ok, Layout.t()}` or `{:error, :invalid_rtf}`.
  """
  @spec read(binary()) :: {:ok, Layout.t()} | {:error, :invalid_rtf}
  def read(bytes) when is_binary(bytes) do
    with {:ok, {paragraphs, notes}} <- parse_rtf(bytes) do
      section = build_section(paragraphs)

      {:ok,
       %Layout{
         sections: [section],
         report: [
           %{level: :info, message: "Parsed #{length(paragraphs)} paragraph(s)", source: "rtf"}
           | notes
         ]
       }}
    end
  end

  # ═════════════════════════════════════════════════════════════════════════
  # Main parse
  # ═════════════════════════════════════════════════════════════════════════

  defp parse_rtf(bin) when is_binary(bin) do
    if byte_size(bin) < 6 or :binary.part(bin, 0, 5) != "{\\rtf" do
      {:error, :invalid_rtf}
    else
      tokens = tokenize(bin)
      {paragraphs, notes} = build_paragraphs(tokens)
      {:ok, {paragraphs, notes}}
    end
  end

  # ═════════════════════════════════════════════════════════════════════════
  # Tokenizer
  # ═════════════════════════════════════════════════════════════════════════
  #
  # Walks the binary byte-by-byte producing a flat, reversed list of tokens:
  #   {:text, string}      — literal text content
  #   {:ctrl, name, param} — control word (param is int or nil)
  #   :start_group         — '{' (ignored structurally, used for skip tracking)
  #   :end_group           — '}'
  #
  # The final result is reversed once at the end.

  defp tokenize(bin), do: do_tokenize(bin, [], "") |> Enum.reverse()

  # ── End of input ────────────────────────────────────────────────────────

  defp do_tokenize(<<>>, tokens, acc), do: emit_text(acc, tokens)

  # ── Group boundaries ────────────────────────────────────────────────────

  defp do_tokenize(<<?{, rest::binary>>, tokens, acc) do
    do_tokenize(rest, [:start_group | emit_text(acc, tokens)], "")
  end

  defp do_tokenize(<<?}, rest::binary>>, tokens, acc) do
    do_tokenize(rest, [:end_group | emit_text(acc, tokens)], "")
  end

  # ── Backslash — escape sequence or control word ─────────────────────────

  defp do_tokenize(<<?\\, rest::binary>>, tokens, acc) do
    case rest do
      # \'xx — hex-encoded character (most common non-ASCII form)
      <<?'::8, h1, h2, r::binary>> ->
        char = hex_to_char(h1, h2)
        do_tokenize(r, tokens, acc <> char)

      # Escaped special characters
      <<?{, r::binary>> ->
        do_tokenize(r, tokens, acc <> "{")

      <<?}, r::binary>> ->
        do_tokenize(r, tokens, acc <> "}")

      <<?\\, r::binary>> ->
        do_tokenize(r, tokens, acc <> "\\")

      # \~ — non-breaking space → regular space
      <<?~, r::binary>> ->
        do_tokenize(r, tokens, acc <> " ")

      # \_ — optional hyphen → regular hyphen
      <<?_, r::binary>> ->
        do_tokenize(r, tokens, acc <> "-")

      # \* — destination marker for ignorable groups (e.g. {\*\generator ...})
      <<?*, r::binary>> ->
        do_tokenize(r, [{:ctrl, "*", nil} | emit_text(acc, tokens)], "")

      # Control word — alphabetic start
      <<c::8, rest2::binary>>
      when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) ->
        {word, param, rest3} = read_control(rest2, <<c>>)
        do_tokenize(rest3, [{:ctrl, word, param} | emit_text(acc, tokens)], "")

      # Any other \X — silently consume the X and continue
      <<_, r::binary>> ->
        do_tokenize(r, tokens, acc)
    end
  end

  # ── Raw control characters (newlines, carriage returns) ─────────────────
  # RTF uses CR/LF as whitespace between constructs; they are not text content.

  defp do_tokenize(<<?\r, rest::binary>>, tokens, acc), do: do_tokenize(rest, tokens, acc)
  defp do_tokenize(<<?\n, rest::binary>>, tokens, acc), do: do_tokenize(rest, tokens, acc)

  # ── Regular text byte ───────────────────────────────────────────────────

  defp do_tokenize(<<c::8, rest::binary>>, tokens, acc) do
    do_tokenize(rest, tokens, acc <> <<c::utf8>>)
  end

  # ═════════════════════════════════════════════════════════════════════════
  # Control word reader
  # ═════════════════════════════════════════════════════════════════════════
  #
  # Reads: alphabetic name + optional numeric parameter + optional space delimiter.
  # The space delimiter is consumed whenever it follows a control word
  # (whether a parameter was present or not).

  defp read_control(bin, acc) do
    {word, rest} = read_letters(bin, acc)
    {param, rest2} = read_numeric_param(rest)
    rest3 = consume_space_delimiter(rest2)
    {word, param, rest3}
  end

  defp read_letters(<<c::8, rest::binary>>, acc)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z),
       do: read_letters(rest, acc <> <<c>>)

  defp read_letters(rest, acc), do: {acc, rest}

  defp read_numeric_param(<<?-, rest::binary>>), do: read_digits(rest, "-")
  defp read_numeric_param(rest), do: read_digits(rest, nil)

  defp read_digits(<<c::8, rest::binary>>, nil) when c >= ?0 and c <= ?9,
    do: read_digits(rest, <<c>>)

  defp read_digits(<<c::8, rest::binary>>, acc) when c >= ?0 and c <= ?9,
    do: read_digits(rest, acc <> <<c>>)

  defp read_digits(rest, nil), do: {nil, rest}
  defp read_digits(rest, acc), do: {String.to_integer(acc), rest}

  defp consume_space_delimiter(<<?\s, rest::binary>>), do: rest
  defp consume_space_delimiter(rest), do: rest

  # ═════════════════════════════════════════════════════════════════════════
  # Hex character decoder
  # ═════════════════════════════════════════════════════════════════════════

  defp hex_to_char(h1, h2) do
    val = String.to_integer(<<h1, h2>>, 16)
    <<val::utf8>>
  end

  defp emit_text("", tokens), do: tokens
  defp emit_text(text, tokens), do: [{:text, text} | tokens]

  # ═════════════════════════════════════════════════════════════════════════
  # Paragraph builder from token list
  # ═════════════════════════════════════════════════════════════════════════
  #
  # Walk tokens accumulating text and emitting paragraphs on \par.
  # Maintains a skip depth for ignoring font-table, colour-table,
  # stylesheet, and \*-destination groups.

  defp build_paragraphs(tokens) do
    {paragraphs, notes} = do_build_paragraphs(tokens, [], "", 0, %{})
    {paragraphs, notes |> Map.keys() |> Enum.map(&build_note/1)}
  end

  defp build_note("table"),
    do: %{level: :unsupported, message: "Table constructs skipped", source: "rtf"}

  defp build_note(_), do: nil

  # ── Normal mode (skip_depth == 0) ───────────────────────────────────────

  # End of input — flush remaining text as final paragraph
  defp do_build_paragraphs([], paras, "", _skip, notes), do: {Enum.reverse(paras), notes}

  defp do_build_paragraphs([], paras, text, _skip, notes),
    do: {Enum.reverse([String.trim(text) | paras]), notes}

  # Group boundaries — structural only, no content impact
  defp do_build_paragraphs([:start_group | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text, 0, notes)

  defp do_build_paragraphs([:end_group | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text, 0, notes)

  # Text content
  defp do_build_paragraphs([{:text, s} | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text <> s, 0, notes)

  # \par — paragraph break
  defp do_build_paragraphs([{:ctrl, "par", _} | rest], paras, text, 0, notes) do
    para = String.trim(text)
    paras = if para == "", do: paras, else: [para | paras]
    do_build_paragraphs(rest, paras, "", 0, notes)
  end

  # \line — line break within paragraph → newline in text
  defp do_build_paragraphs([{:ctrl, "line", _} | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text <> "\n", 0, notes)

  # \tab — tab character
  defp do_build_paragraphs([{:ctrl, "tab", _} | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text <> "\t", 0, notes)

  # \page — page break (ignored; RTF is a single continuous document for us)
  defp do_build_paragraphs([{:ctrl, "page", _} | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text, 0, notes)

  # \sect — section break (ignored)
  defp do_build_paragraphs([{:ctrl, "sect", _} | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text, 0, notes)

  # Enter skip mode for font table, colour table, stylesheet
  defp do_build_paragraphs([{:ctrl, word, _} | rest], paras, text, 0, notes)
       when word in ~w(fonttbl colortbl stylesheet) do
    do_build_paragraphs(rest, paras, text, 1, notes)
  end

  # Enter skip mode for \* destination groups
  defp do_build_paragraphs([{:ctrl, "*", _} | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text, 1, notes)

  # Table constructs — note as unsupported (deduplicated in notes map)
  defp do_build_paragraphs([{:ctrl, "cell", _} | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text, 0, Map.put(notes, "table", true))

  defp do_build_paragraphs([{:ctrl, "row", _} | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text, 0, notes)

  defp do_build_paragraphs([{:ctrl, "trowd", _} | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text, 0, notes)

  defp do_build_paragraphs([{:ctrl, "intbl", _} | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text, 0, notes)

  # All other control words — skip silently
  defp do_build_paragraphs([{:ctrl, _, _} | rest], paras, text, 0, notes),
    do: do_build_paragraphs(rest, paras, text, 0, notes)

  # ── Skip mode (skip_depth > 0) ──────────────────────────────────────────
  # While skipping, we only track group depth to know when to resume normal
  # processing. All content and control words are discarded.

  defp do_build_paragraphs([:start_group | rest], paras, text, skip, notes) when skip > 0,
    do: do_build_paragraphs(rest, paras, text, skip + 1, notes)

  defp do_build_paragraphs([:end_group | rest], paras, text, 1, notes),
    do: do_build_paragraphs(rest, paras, text, 0, notes)

  defp do_build_paragraphs([:end_group | rest], paras, text, skip, notes) when skip > 1,
    do: do_build_paragraphs(rest, paras, text, skip - 1, notes)

  defp do_build_paragraphs([_ | rest], paras, text, skip, notes) when skip > 0,
    do: do_build_paragraphs(rest, paras, text, skip, notes)

  # ═════════════════════════════════════════════════════════════════════════
  # Layout building
  # ═════════════════════════════════════════════════════════════════════════

  defp build_section(paragraphs) do
    blocks = Enum.map(paragraphs, &{:paragraph, &1})
    %{Section.new(:page) | blocks: blocks}
  end
end
