defmodule Quire.Gate2SearchEqualityTest do
  @moduledoc """
  Gate 2 (pdf-4k4) verify #5: the client PDFFindController path and the
  server `document_page_text` / `websearch_to_tsquery` path return the same
  hit sets on `500_pages.pdf`.

  The client path is pdf.js's PDFFindController; its matching semantics are
  mirrored here (lowercase unless case-sensitive, diacritics stripped,
  whitespace collapsed, whole-word boundary checks) so the two paths are
  compared on equal terms. The fixture now has page-distinct text
  ("Page N" per page) — see scripts/generate_fixtures.exs.
  """

  use Quire.DataCase, async: false

  import Ecto.Query
  import Quire.AccountsFixtures

  alias Quire.Documents.PageText

  @fixture Path.expand("../fixtures/pdfs/500_pages.pdf", __DIR__)

  setup do
    user = user_fixture()
    scope = Quire.Accounts.Scope.for_user(user)

    {:ok, bytes} = File.read(@fixture)
    {:ok, %{document: doc}} = Quire.Documents.ingest(bytes, scope, title: "500_pages.pdf")

    # Run the ingest's background text extraction synchronously — this is
    # what populates document_page_text (the server search source).
    assert %{success: success, failure: failure} = Oban.drain_queue(queue: :render)
    assert success >= 1, "text extraction should have succeeded"
    assert failure == 0, "text extraction should not have failed"

    contents =
      Repo.all(
        from pt in PageText,
          where: pt.revision_id == ^doc.current_revision_id,
          order_by: pt.page_index
      )

    assert length(contents) == 500, "expected page text for all 500 pages"

    %{revision_id: doc.current_revision_id, contents: contents}
  end

  # ── PDFFindController-equivalent client matcher ─────────────────────────

  # pdf.js PDFFindController._normalize: lowercase unless case-sensitive,
  # strip diacritics, collapse whitespace runs (NormalizeWhitespace).
  defp normalize(text, match_case) do
    text = if match_case, do: text, else: String.downcase(text)

    text =
      text
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{M}/u, "")
      |> String.normalize(:nfc)

    text |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  # pdf.js _calculateMatch: plain substring scan with optional whole-word
  # boundaries on the normalized page text.
  defp client_matches?(content, query, opts) do
    match_case = Keyword.get(opts, :match_case, false)
    whole_word = Keyword.get(opts, :whole_word, false)

    hay = normalize(content, match_case)
    needle = if match_case, do: query, else: String.downcase(query)

    find_all(hay, needle, whole_word) != []
  end

  defp find_all(_hay, "", _whole_word), do: []

  defp find_all(hay, needle, whole_word) do
    len = String.length(needle)

    hay
    |> :binary.matches(needle)
    |> Enum.filter(fn {offset, _} ->
      if whole_word do
        left_ok =
          offset == 0 or
            not Regex.match?(~r/[\w]/u, String.at(hay, offset - 1))

        right_at = offset + len

        right_ok =
          right_at >= String.length(hay) or
            not Regex.match?(~r/[\w]/u, String.at(hay, right_at))

        left_ok and right_ok
      else
        true
      end
    end)
  end

  # ── Tests ────────────────────────────────────────────────────────────────

  @queries [
    # {query, opts} — a spread covering case, whole-word and no-match cases
    {"Page", []},
    {"Page 1", []},
    {"page 50", []},
    {"Page 100", []},
    {"Page 500", []},
    {"Page 5", []},
    {"Page 5", whole_word: true},
    {"Page 50", whole_word: true},
    {"Page", match_case: true},
    {"PAGE 250", match_case: true},
    {"Page 333", whole_word: true, match_case: true},
    {"zzz_nothing", []}
  ]

  test "server search and PDFFindController path agree on hit pages", %{
    revision_id: revision_id,
    contents: contents
  } do
    for {query, opts} <- @queries do
      {:ok, server_hits} = Quire.Search.search(revision_id, query, opts)

      server_pages =
        server_hits |> Enum.map(& &1.page) |> MapSet.new()

      client_pages =
        contents
        |> Enum.filter(fn pt -> client_matches?(pt.content, query, opts) end)
        |> Enum.map(&(&1.page_index + 1))
        |> MapSet.new()

      assert server_pages == client_pages,
             """
             query #{inspect(query)} opts=#{inspect(opts)}:
               server: #{inspect(Enum.sort(server_pages))}
               client: #{inspect(Enum.sort(client_pages))}
             """
    end
  end

  test "hit counts agree for a query with many matches", %{
    revision_id: revision_id,
    contents: contents
  } do
    query = "Page"
    {:ok, server_hits} = Quire.Search.search(revision_id, query)

    client_count =
      contents
      |> Enum.filter(fn pt -> client_matches?(pt.content, query, []) end)
      |> length()

    assert length(server_hits) >= 500
    assert client_count == 500
    assert length(Enum.uniq_by(server_hits, & &1.page)) == 500
  end
end
