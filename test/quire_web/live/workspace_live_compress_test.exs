defmodule QuireWeb.WorkspaceLiveCompressTest do
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures
  import Ecto.Query

  alias Quire.Repo
  alias Quire.Documents.Document
  alias Quire.Documents.Revision

  @fixtures Path.expand("../../fixtures/pdfs", __DIR__)
  @compress_btn ~s{button[phx-click="open_compress_wizard"]}
  @dialog ~s{div[role="dialog"][aria-label="Compress PDF"]}

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp doc_fixture(user) do
    bytes = fixture("50mb_images.pdf")
    {:ok, ref} = Quire.Storage.put(bytes, name: "images.pdf", content_type: "application/pdf")

    doc =
      %Document{id: Ecto.UUID.generate(), user_id: user.id, title: "images.pdf", page_count: 250}
      |> Repo.insert!()

    source_map = %{
      "storage_ref" => %{
        "adapter" => to_string(ref.adapter),
        "key" => ref.key,
        "name" => ref.name,
        "content_type" => ref.content_type,
        "byte_size" => ref.byte_size
      },
      "filename" => "images.pdf"
    }

    rev =
      %Revision{document_id: doc.id, label: "Original", source: source_map}
      |> Repo.insert!()

    doc
    |> Ecto.Changeset.change(%{current_revision_id: rev.id})
    |> Repo.update!()

    doc
  end

  describe "compress wizard (T-083)" do
    test "opens with presets and the accessibility opt-in", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      conn = conn |> log_in_user(user)

      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")
      lv |> element(~s{button[role="tab"][phx-value-tab="create-convert"]}) |> render_click()
      lv |> element(@compress_btn) |> render_click()

      assert has_element?(lv, @dialog)
      assert has_element?(lv, "#compress-preset option[value='medium'][selected]")
      assert has_element?(lv, "#compress-preset option[value='custom']")
      assert has_element?(lv, "#compress-remove-a11y")
      assert has_element?(lv, "#compress-preview-btn")
      assert has_element?(lv, "#compress-commit-btn")
      refute has_element?(lv, "#compress-custom-params")
    end

    test "custom preset reveals quality/max-width params", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      conn = conn |> log_in_user(user)

      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")
      lv |> element(~s{button[role="tab"][phx-value-tab="create-convert"]}) |> render_click()
      lv |> element(@compress_btn) |> render_click()

      lv |> element("#compress-preset") |> render_change(%{"preset" => "custom"})
      assert has_element?(lv, "#compress-custom-params")
    end

    test "preview shows a before/after size comparison and page previews", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      conn = conn |> log_in_user(user)

      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")
      lv |> element(~s{button[role="tab"][phx-value-tab="create-convert"]}) |> render_click()
      lv |> element(@compress_btn) |> render_click()

      # High preset on the 50 MB images fixture → visibly smaller
      lv |> element("#compress-preset") |> render_change(%{"preset" => "high"})
      lv |> element("#compress-preview-btn") |> render_click()

      assert has_element?(lv, "#compress-preview")
      assert render(lv) =~ "smaller"
      assert has_element?(lv, "#compress-preview-before")
      assert has_element?(lv, "#compress-preview-after")

      # commit creates a new revision + journals doc.compress
      lv |> element("#compress-commit-btn") |> render_click()

      fresh = Repo.get!(Document, doc.id)
      rev = Repo.get!(Revision, fresh.current_revision_id)
      assert rev.label == "Compressed"
      assert rev.id != doc.current_revision_id

      {:ok, session} = Quire.Editing.open_session(doc.id, user.id)
      state = Quire.Editing.EditSession.get_state(session)
      assert Enum.any?(state.journal, &(&1.kind == "doc.compress"))
    end
  end
end
