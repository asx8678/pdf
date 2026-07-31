#!/usr/bin/env elixir
# mix run scripts/seed_workspace_fixtures.exs
#
# Ingests the Gate-2-relevant corpus fixtures as documents owned by the dev
# user, so Playwright e2e specs (test/visual) can open them in the real
# viewer. Idempotent: existing documents with the same titles are replaced.

Application.ensure_all_started(:quire)

alias Quire.Repo
alias Quire.Documents.{Document, Revision}

import Ecto.Query

user = Quire.Accounts.get_user_by_email("dev@quire.test") || raise("seed user missing — run mix run priv/repo/seeds.exs first")
scope = Quire.Accounts.Scope.for_user(user)

fixtures = [
  {"cjk.pdf", "cjk.pdf"},
  {"rtl_arabic.pdf", "rtl_arabic.pdf"},
  {"rotated_pages.pdf", "rotated_pages.pdf"},
  {"cropped_nonzero_origin.pdf", "cropped_nonzero_origin.pdf"},
  {"500_pages.pdf", "500_pages.pdf"},
  {"50mb_images.pdf", "50mb_images.pdf"}
]

urls =
  for {file, title} <- fixtures do
    # Remove any previous document with this title (revisions cascade).
    Repo.delete_all(from d in Document, where: d.title == ^title and d.user_id == ^user.id)

    path = Path.join("test/fixtures/pdfs", file)
    {:ok, bytes} = File.read(path)

    case Quire.Documents.ingest(bytes, scope, title: title) do
      {:ok, %{document: doc, document_url: _url}} ->
        IO.puts("seeded #{title} -> /workspace/#{doc.id} (#{doc.page_count} pages)")
        {title, "/workspace/#{doc.id}"}

      {:error, reason} ->
        IO.puts("FAILED #{title}: #{inspect(reason)}")
        {title, nil}
    end
  end

# Emit a fixture -> workspace path map for the Playwright specs
# (test/visual/gate2.spec.ts). Document ids change on every seed run.
File.mkdir_p!("test/visual")
File.write!(
  Path.join("test/visual", "fixture_urls.json"),
  Jason.encode!(Map.new(urls), pretty: true)
)
IO.puts("wrote test/visual/fixture_urls.json")
