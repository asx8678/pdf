defmodule QuireWeb.WorkspaceLivePdfaTest do
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures

  alias Quire.Repo
  alias Quire.Documents.Document
  alias Quire.Documents.Revision

  @fixtures Path.expand("../../fixtures/pdfs", __DIR__)
  @pdfa_btn ~s{button[phx-click="open_pdfa_wizard"]}
  @dialog ~s{div[role="dialog"][aria-label="PDF/A — best-effort conversion"]}

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

  describe "PDF/A wizard (T-084)" do
    test "opens with the best-effort label and a convert button", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      conn = conn |> log_in_user(user)

      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")
      lv |> element(~s{button[role="tab"][phx-value-tab="create-convert"]}) |> render_click()
      lv |> element(@pdfa_btn) |> render_click()

      assert has_element?(lv, @dialog)
      assert render(lv) =~ "best-effort conversion"
      assert has_element?(lv, "#pdfa-convert-btn")
      refute has_element?(lv, "#pdfa-report")
    end

    test "convert shows the conformance report with pass and not-verified checks", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      conn = conn |> log_in_user(user)

      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")
      lv |> element(~s{button[role="tab"][phx-value-tab="create-convert"]}) |> render_click()
      lv |> element(@pdfa_btn) |> render_click()

      lv |> element("#pdfa-convert-btn") |> render_click()

      assert has_element?(lv, "#pdfa-report")
      assert render(lv) =~ "Conformance report"
      # the not-verified font check is listed explicitly
      assert render(lv) =~ "Font embedding"
      assert render(lv) =~ "could not be verified"

      # conversion saved as a new revision + journal entry
      fresh = Repo.get!(Document, doc.id)
      rev = Repo.get!(Revision, fresh.current_revision_id)
      assert rev.label == "PDF/A"

      {:ok, session} = Quire.Editing.open_session(doc.id, user.id)
      state = Quire.Editing.EditSession.get_state(session)
      assert Enum.any?(state.journal, &(&1.kind == "doc.convert"))
    end
  end
end
