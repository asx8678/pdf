defmodule Quire.Search do
  @moduledoc """
  Server-side document search (§5.2, bfm).

  Two-stage search: the GIN/tsvector index acts as a page pre-filter,
  then an Elixir substring scan runs over the matching pages' raw text
  to produce exact character offsets and span-→rect mapping.

  The normalisation rules are shared with pdf.js's `PDFFindController`,
  so results are comparable between client and server.
  """

  import Ecto.Query

  alias Quire.Repo
  alias Quire.Documents.PageText

  @typedoc """
  A single search hit.

    * `:page` — 1-indexed page number
    * `:text` — context snippet around the match
    * `:offset` — character offset in the raw content
    * `:bounds` — bounding box of the match in PDF space (from spans)
  """
  @type hit :: %{
          required(:page) => pos_integer(),
          required(:text) => String.t(),
          required(:offset) => non_neg_integer(),
          required(:bounds) => list()
        }

  @typedoc """
  Search options:

    * `:match_case` — case-sensitive search (default `false`)
    * `:whole_word` — match whole words only (default `false`)
    * `:page` — restrict to a single page (default `nil` = all pages)
  """
  @type opts :: [
          match_case: boolean(),
          whole_word: boolean(),
          page: pos_integer() | nil
        ]

  @doc """
  Searches document text under `revision_id` for `query`.

  Returns `{:ok, [hit()]}` — a list of hits, empty when no matches.
  """
  @spec search(String.t(), String.t(), opts()) :: {:ok, [hit()]} | {:error, term()}
  def search(revision_id, query, opts \\ []) do
    match_case = Keyword.get(opts, :match_case, false)
    whole_word = Keyword.get(opts, :whole_word, false)
    page_filter = Keyword.get(opts, :page)

    with {:ok, candidate_pages} <- prefilter(revision_id, query, page_filter),
         {:ok, hits} <- scan_pages(candidate_pages, query, match_case, whole_word) do
      {:ok, hits}
    end
  end

  # ── Stage 1: GIN/tsvector pre-filter ────────────────────────────────────

  defp prefilter(revision_id, query, page_filter) do
    # Build a tsquery from the user's search string.
    # Use websearch_to_tsquery which handles quoting, OR, etc.
    tsquery = "websearch_to_tsquery('simple', #{escape_tsquery(query)})"

    base =
      from pt in PageText,
        where: pt.revision_id == ^revision_id,
        # rub: false — rub   only if something is not a full match
        where:
          fragment(
            "? @@ ?",
            pt.search,
            fragment(^tsquery)
          ),
        select: %{page_index: pt.page_index, content: pt.content, spans: pt.spans}

    query =
      if page_filter do
        from [pt] in base, where: pt.page_index == ^(page_filter - 1)
      else
        base
      end

    {:ok, Repo.all(query)}
  rescue
    e ->
      {:error, "Search query error: #{Exception.message(e)}"}
  end

  defp escape_tsquery(query) do
    # Sanitise the query for websearch_to_tsquery: remove characters that
    # could break the tsquery parser, keep basic operators.
    query
    |> String.replace(~r/[^\w\s"\-]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> then(fn q -> "'#{q}'" end)
  end

  # ── Stage 2: Elixir substring scan ───────────────────────────────────────

  defp scan_pages(candidate_pages, query, match_case, whole_word) do
    hits =
      candidate_pages
      |> Enum.flat_map(fn %{page_index: page_idx, content: content, spans: spans} ->
        page_idx = page_idx + 1
        scan_content(content, query, match_case, whole_word, page_idx, spans)
      end)

    {:ok, hits}
  end

  defp scan_content(content, query, match_case, whole_word, page_idx, spans) do
    search_content =
      if is_binary(content),
        do: if(match_case, do: content, else: String.downcase(content)),
        else: ""

    search_query =
      if match_case, do: query, else: String.downcase(query)

    query_len = String.length(query)
    content_len = String.length(search_content || "")

    # Find all matches with positions
    offsets = search_for_matches(search_content, search_query, match_case, whole_word)

    # Map each offset to a span → bounds
    spans_list = spans || []

    Enum.map(offsets, fn offset ->
      {span_idx, _span_start} = find_span(spans_list, offset)

      bounds =
        if span_idx >= 0 && span_idx < length(spans_list) do
          Enum.at(spans_list, span_idx)[:bounds]
        else
          nil
        end

      # Context snippet ±30 chars
      start_ctx = max(0, offset - 30)
      end_ctx = min(content_len, offset + query_len + 30)

      snippet =
        search_content
        |> String.slice(start_ctx, end_ctx - start_ctx)
        |> String.replace("\n", " ")
        |> String.trim()

      %{
        page: page_idx,
        text: snippet,
        offset: offset,
        bounds: bounds
      }
    end)
  end

  @spec search_for_matches(String.t(), String.t(), boolean(), boolean()) :: [non_neg_integer()]
  defp search_for_matches(content, query_str, match_case, whole_word) do
    text = if is_binary(content), do: content, else: ""
    q = if match_case, do: query_str, else: String.downcase(query_str)
    escaped = Regex.escape(q)

    source =
      if whole_word, do: "\\b" <> escaped <> "\\b", else: escaped

    source =
      if match_case, do: source, else: "(?i)" <> source

    case Regex.compile(source) do
      {:ok, %Regex{} = pattern} -> run_regex_scan(text, pattern)
      {:error, _} -> []
    end
  end

  defp run_regex_scan(text, %Regex{} = pattern) do
    # Use :re.run directly to avoid Elixir type checker ambiguity.
    # pattern.regex is the internal compiled form.
    opts = [{:return, :index}]

    case :re.run(text, pattern.re_pattern, opts) do
      {:match, results} ->
        Enum.map(results, fn [{offset, _len}] -> offset end)

      :nomatch ->
        []
    end
  end

  # Walk span list to find which span contains a given character offset.
  # Returns {span_index, character_offset_within_span}.
  defp find_span(spans, char_offset, idx \\ 0, accumulated \\ 0)

  defp find_span([], _char_offset, _idx, _accumulated), do: {-1, 0}

  defp find_span([span | rest], char_offset, idx, accumulated) do
    text = span[:text] || ""
    span_start = accumulated
    span_end = span_start + String.length(text)

    if char_offset >= span_start && char_offset < span_end do
      {idx, char_offset - span_start}
    else
      # +1 for the newline separator between spans
      find_span(rest, char_offset, idx + 1, span_end + 1)
    end
  end
end
