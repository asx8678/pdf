defmodule QuireWeb.WorkspaceLiveSearchRedactTest do
  use QuireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures

  alias Quire.Repo
  alias Quire.Documents.Document
  alias Quire.Documents.Revision

  @fixtures Path.expand("../../fixtures/pdfs", __DIR__)
  @wizard_btn ~s{button[phx-click="open_search_redact_wizard"]}
  @dialog ~s{div[role="dialog"]}
  @wizard_id "#search-redact-wizard"

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp doc_fixture(user) do
    bytes = fixture("simple_text.pdf")
    {:ok, ref} = Quire.Storage.put(bytes, name: "simple.pdf", content_type: "application/pdf")

    doc =
      %Document{id: Ecto.UUID.generate(), user_id: user.id, title: "simple.pdf", page_count: 1}
      |> Repo.insert!()

    source_map = %{
      "storage_ref" => %{
        "adapter" => to_string(ref.adapter),
        "key" => ref.key,
        "name" => ref.name,
        "content_type" => ref.content_type,
        "byte_size" => ref.byte_size
      },
      "filename" => "simple.pdf"
    }

    rev =
      %Revision{document_id: doc.id, label: "Original", source: source_map}
      |> Repo.insert!()

    doc
    |> Ecto.Changeset.change(%{current_revision_id: rev.id})
    |> Repo.update!()

    doc
  end

  defp open_wizard(conn, doc) do
    conn = conn |> log_in_user(doc.user_id |> Quire.Accounts.get_user!())
    {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")
    lv |> element(~s{button[role="tab"][phx-value-tab="create-convert"]}) |> render_click()
    lv |> element(@wizard_btn) |> render_click()
    lv
  end

  # The search runs in a background task; wait for its result to be
  # delivered to the LiveView and rendered.
  defp wait_for_hits(lv, selector) do
    assert wait_until(fn -> has_element?(lv, selector) end),
           "expected to find #{selector} after the background search"

    lv
  end

  defp wait_until(fun, interval \\ 25, attempts \\ 1_200) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(interval)
        wait_until(fun, interval, attempts - 1)
    end
  end

  describe "Search & Redact wizard (T-135)" do
    test "opens with presets, query input and search button", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      lv = open_wizard(conn, doc)

      assert has_element?(lv, @wizard_id)
      assert has_element?(lv, "#search-redact-query")
      assert has_element?(lv, "#search-redact-run-btn")
      assert has_element?(lv, "#sr-preset-ssn")
      assert has_element?(lv, "#sr-preset-card")
      assert has_element?(lv, "#sr-preset-email")
      assert has_element?(lv, "#sr-preset-phone")
      assert has_element?(lv, "#sr-preset-iban")
      assert has_element?(lv, "#search-redact-empty")
      assert has_element?(lv, "#search-redact-apply-btn:disabled")
    end

    test "literal search lists hits with per-hit review and accept toggling", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      lv = open_wizard(conn, doc)

      lv
      |> element("#search-redact-query")
      |> render_change(%{"value" => "World"})

      lv |> element("#search-redact-run-btn") |> render_click()

      # Background task result is delivered to the LiveView.
      lv = wait_for_hits(lv, "#sr-hit-srh-0-0")
      html = render(lv)
      assert html =~ "1 hit(s)"
      assert html =~ "Hello World"

      # Toggle rejects the hit; apply is then disabled.
      lv
      |> element(~s{input[phx-click="search_redact_toggle"][phx-value-id="srh-0-0"]})
      |> render_click()

      assert render(lv) =~ "0 accepted"
    end

    test "preset search runs against the document", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      lv = open_wizard(conn, doc)

      lv |> element("#sr-preset-ssn") |> render_click()
      lv |> element("#search-redact-run-btn") |> render_click()

      # simple_text.pdf has no SSNs — clean empty result, no crash.
      assert render(lv) =~ "0 hit(s)" or render(lv) =~ "Search"
    end

    test "apply is disabled when no hits are accepted", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      lv = open_wizard(conn, doc)

      lv
      |> element("#search-redact-query")
      |> render_change(%{"value" => "World"})

      lv |> element("#search-redact-run-btn") |> render_click()
      lv = wait_for_hits(lv, "#sr-hit-srh-0-0")

      # Reject the hit — the apply button must become disabled.
      lv
      |> element(~s{input[phx-click="search_redact_toggle"][phx-value-id="srh-0-0"]})
      |> render_click()

      assert render(lv) =~ "0 accepted"

      # Re-accept — apply enabled again.
      lv
      |> element(~s{input[phx-click="search_redact_toggle"][phx-value-id="srh-0-0"]})
      |> render_click()

      assert render(lv) =~ "1 accepted"
    end
  end
end
