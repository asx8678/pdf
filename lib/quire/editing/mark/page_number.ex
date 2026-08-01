defmodule Quire.Editing.Mark.PageNumber do
  @moduledoc """
  Renders a page-number stamp's text for one page (plan3.md §9.5, T-095).

  Formats:

    * `"1"` — Arabic numerals (1, 2, 3, …)
    * `"i"` — lowercase Roman numerals
    * `"I"` — uppercase Roman numerals
    * `"a"` — lowercase letters (a, b, …, z, aa, ab, …)
    * `"A"` — uppercase letters
    * `"page_of"` — `Page 1 of N`

  "Page 1 of N" is always Arabic in both slots (matching the reference
  implementations of the same control), regardless of the base `:format` —
  the format drives the per-page number only.
  """

  @roman_threshold 4000

  @doc "The six supported format keys."
  @spec formats() :: [String.t()]
  def formats, do: ~w(1 i I a A page_of)

  @doc """
  Renders the stamp text for a single page.

  ## Parameters

    * `page_index` — zero-based page index within the document
    * `page_count` — total number of pages in the document
    * `opts` — `:format` (one of `formats/0`, default `"1"`),
      `:start_at` (number the first *stamped* page at this value,
      default 1), `:pages` (page-range selector, see
      `Quire.Editing.Mark.PageRange`).

  Returns `nil` when the page is outside the page range.
  """
  @spec render(non_neg_integer(), pos_integer(), keyword()) :: String.t() | nil
  def render(page_index, page_count, opts \\ []) do
    format = Keyword.get(opts, :format, "1")
    start_at = Keyword.get(opts, :start_at, 1)

    if Quire.Editing.Mark.PageRange.include?(page_index, Keyword.get(opts, :pages)) do
      numbered = start_at + page_index

      case format do
        "page_of" -> "Page #{numbered} of #{page_count}"
        format -> format_number(numbered, format)
      end
    end
  end

  defp format_number(number, "1"), do: Integer.to_string(number)
  defp format_number(number, "i"), do: roman(number) |> String.downcase()
  defp format_number(number, "I"), do: roman(number)
  defp format_number(number, "a"), do: alpha(number, 97)
  defp format_number(number, "A"), do: alpha(number, 65)
  defp format_number(_number, other), do: other

  # ── Roman numerals ─────────────────────────────────────────────────────

  @roman_pairs [
    {1000, "M"},
    {900, "CM"},
    {500, "D"},
    {400, "CD"},
    {100, "C"},
    {90, "XC"},
    {50, "L"},
    {40, "XL"},
    {10, "X"},
    {9, "IX"},
    {5, "V"},
    {4, "IV"},
    {1, "I"}
  ]

  @doc """
  Converts a positive integer to uppercase Roman numerals.

  Values ≥ 4000 (beyond classical Roman numbering) return the Arabic
  digits as a graceful fallback. Returns `"0"` for `0` so the caller
  always receives a string.
  """
  @spec roman(non_neg_integer()) :: String.t()
  def roman(0), do: "0"
  def roman(number) when is_integer(number) and number < 0, do: "0"

  def roman(number) when is_integer(number) and number < @roman_threshold do
    do_roman(number, @roman_pairs, "")
  end

  def roman(number) when is_integer(number), do: Integer.to_string(number)

  defp do_roman(0, _pairs, acc), do: acc
  defp do_roman(number, [{value, glyph} | rest], acc) do
    if number >= value do
      do_roman(number - value, @roman_pairs, acc <> glyph)
    else
      do_roman(number, rest, acc)
    end
  end

  # ── Letter numbering (a, b, … z, aa, ab, …) ────────────────────────────

  # Spreadsheet-style bijective base-26: 1 → a, 26 → z, 27 → aa.
  defp alpha(number, base) when is_integer(number) and number > 0 do
    number
    |> letters(base)
    |> IO.iodata_to_binary()
  end

  defp alpha(number, _base), do: Integer.to_string(number)

  defp letters(0, _base), do: []
  defp letters(number, base) do
    letters(div(number - 1, 26), base) ++ [<<rem(number - 1, 26) + base>>]
  end
end
