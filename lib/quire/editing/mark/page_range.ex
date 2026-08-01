defmodule Quire.Editing.Mark.PageRange do
  @moduledoc """
  Page-range selection shared by all stamping ops (plan3.md §9.5, T-095).

  Selectors are expressed in **one-based, inclusive** user terms, matching
  what an "Apply to pages" control offers:

    * `"all"` (default) — every page
    * `"range"` — `"from"` / `"to"` (one-based, inclusive; `nil` means the
      first / last page)
    * `"odd"` — one-based odd pages (1, 3, 5, …)
    * `"even"` — one-based even pages (2, 4, 6, …)
    * `"custom"` — a list of one-based page numbers in `"pages"`

  ## Examples

      PageRange.include?(3, %{"mode" => "range", "from" => 2, "to" => 4})
      #=> true          (page 4, one-based)

      PageRange.include?(4, %{"mode" => "odd"})
      #=> false         (page 5, one-based, is odd)

  When a selector is absent, `nil`, or `"all"`, every page is included.
  """

  @modes ~w(all range odd even custom)

  @doc "The accepted selector modes."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc """
  Returns `true` when the zero-based `page_index` is inside the selector.

  A `nil` selector includes every page. Invalid modes and non-numeric
  bounds fail closed (the page is excluded) rather than raising.
  """
  @spec include?(non_neg_integer(), map() | nil) :: boolean()
  def include?(_page_index, nil), do: true
  def include?(_page_index, selector) when not is_map(selector), do: true

  def include?(page_index, selector) do
    one_based = page_index + 1

    case selector_mode(selector) do
      "all" -> true
      "range" -> in_range?(one_based, selector)
      "odd" -> Integer.mod(one_based, 2) == 1
      "even" -> Integer.mod(one_based, 2) == 0
      "custom" -> one_based in custom_pages(selector)
      _other -> true
    end
  end

  defp selector_mode(selector) do
    case selector["mode"] do
      mode when is_binary(mode) -> mode
      _ -> "all"
    end
  end

  defp in_range?(one_based, selector) do
    from = bound(selector["from"], 1)
    to = bound(selector["to"], nil)

    cond do
      is_nil(from) -> is_nil(to) or one_based <= to
      is_nil(to) -> one_based >= from
      true -> one_based >= from and one_based <= to
    end
  end

  defp bound(nil, default), do: default
  defp bound(value, _default) when is_integer(value), do: value

  defp bound(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp bound(_value, default), do: default

  defp custom_pages(selector) do
    case selector["pages"] do
      pages when is_list(pages) ->
        Enum.map(pages, fn page -> integer(page) end)

      _ ->
        []
    end
    |> Enum.filter(&(not is_nil(&1)))
    |> Enum.uniq()
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp integer(_value), do: nil
end
