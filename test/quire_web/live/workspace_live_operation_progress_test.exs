defmodule QuireWeb.WorkspaceLiveOperationProgressTest do
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures
  import Ecto.Query

  alias Quire.Repo
  alias Quire.Documents.Document

  @fixtures Path.expand("../../fixtures/pdfs", __DIR__)

  defp doc_fixture(user) do
    bytes = File.read!(Path.join(@fixtures, "simple_text.pdf"))
    {:ok, ref} = Quire.Storage.put(bytes, name: "simple.pdf", content_type: "application/pdf")

    doc =
      %Document{id: Ecto.UUID.generate(), user_id: user.id, title: "simple.pdf", page_count: 1}
      |> Repo.insert!()

    doc
  end

  describe "operation progress UI (T-086)" do
    test "toasts and status strip update live from PubSub broadcasts", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      conn = conn |> log_in_user(user)

      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")

      # simulate a worker broadcasting progress for this document
      Phoenix.PubSub.broadcast(
        Quire.PubSub,
        "document:#{doc.id}",
        {:operation_progress, "op-1", 10}
      )

      Phoenix.PubSub.broadcast(
        Quire.PubSub,
        "document:#{doc.id}",
        {:operation_progress, "op-1", 55}
      )

      assert has_element?(lv, "#op-status-strip")
      assert render(lv) =~ "operation running"
      assert has_element?(lv, ~s{div[id="op-toast-op-1"][role="alert"]})

      # completion turns the toast green and removes the running strip
      Phoenix.PubSub.broadcast(
        Quire.PubSub,
        "document:#{doc.id}",
        {:operation_completed, "op-1", doc.id}
      )

      refute has_element?(lv, "#op-status-strip")
      assert render(lv) =~ "Conversion complete"

      # dismissal removes the toast
      lv |> element(~s{button[aria-label="Dismiss"]}) |> render_click()
      refute has_element?(lv, ~s{div[id="op-toast-op-1"]})
    end

    test "failed jobs show a plain-language cause", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      conn = conn |> log_in_user(user)

      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")

      Phoenix.PubSub.broadcast(
        Quire.PubSub,
        "document:#{doc.id}",
        {:operation_failed, "op-2", doc.id, "The file is not a readable PDF"}
      )

      assert has_element?(lv, ~s{div[id="op-toast-op-2"][role="alert"]})
      assert render(lv) =~ "The file is not a readable PDF"
      refute render(lv) =~ "inspect("
    end
  end
end
