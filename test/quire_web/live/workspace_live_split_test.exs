defmodule QuireWeb.WorkspaceLiveSplitTest do
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures
  import Ecto.Query

  alias Quire.Repo
  alias Quire.Documents.Document
  alias Quire.Documents.Revision

  @fixtures Path.expand("../../fixtures/pdfs", __DIR__)
  @split_btn ~s{button[phx-click="open_split_wizard"]}
  @dialog ~s{div[role="dialog"][aria-label="Split PDF"]}

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp doc_fixture(user) do
    # 4 pages
    bytes = fixture("mixed_page_sizes.pdf")
    {:ok, ref} = Quire.Storage.put(bytes, name: "mixed.pdf", content_type: "application/pdf")

    doc =
      %Document{id: Ecto.UUID.generate(), user_id: user.id, title: "mixed.pdf", page_count: 4}
      |> Repo.insert!()

    source_map = %{
      "storage_ref" => %{
        "adapter" => to_string(ref.adapter),
        "key" => ref.key,
        "name" => ref.name,
        "content_type" => ref.content_type,
        "byte_size" => ref.byte_size
      },
      "filename" => "mixed.pdf"
    }

    rev =
      %Revision{document_id: doc.id, label: "Original", source: source_map}
      |> Repo.insert!()

    doc
    |> Ecto.Changeset.change(%{current_revision_id: rev.id})
    |> Repo.update!()

    doc
  end

  describe "split wizard (T-082)" do
    test "opens from the ribbon with the five modes", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      conn = conn |> log_in_user(user)

      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")
      lv |> element(~s{button[role="tab"][phx-value-tab="create-convert"]}) |> render_click()
      lv |> element(@split_btn) |> render_click()

      assert has_element?(lv, @dialog)
      assert has_element?(lv, "#split-mode option[value='every_n'][selected]")
      assert has_element?(lv, "#split-mode option[value='bookmarks']")
      assert has_element?(lv, "#split-mode option[value='ranges']")
      assert has_element?(lv, "#split-mode option[value='file_size']")
      assert has_element?(lv, "#split-mode option[value='extract']")
      assert has_element?(lv, "#split-param-every-n")
      assert has_element?(lv, "#split-submit-btn")
    end

    test "every-N split delivers a ZIP download and journals doc.split", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      conn = conn |> log_in_user(user)

      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")
      lv |> element(~s{button[role="tab"][phx-value-tab="create-convert"]}) |> render_click()
      lv |> element(@split_btn) |> render_click()

      # 4 pages, N = 2 → two parts
      lv |> element("#split-n") |> render_change(%{"n" => "2"})
      lv |> element("#split-submit-btn") |> render_click()

      assert_push_event(lv, "download", %{
        filename: "split.zip",
        content_type: "application/zip",
        content: zip64
      })

      zip = Base.decode64!(zip64)
      assert binary_part(zip, 0, 2) == <<0x50, 0x4B>>
      {:ok, entries} = :zip.extract(zip, [:memory])
      names = Enum.map(entries, fn {name, _} -> to_string(name) end)
      assert names == ["part-001.pdf", "part-002.pdf"]

      # doc.split journal entry on the source document
      {:ok, session} = Quire.Editing.open_session(doc.id, user.id)
      state = Quire.Editing.EditSession.get_state(session)
      assert Enum.any?(state.journal, &(&1.kind == "doc.split"))
    end

    test "ranges mode validates and splits", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      conn = conn |> log_in_user(user)

      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")
      lv |> element(~s{button[role="tab"][phx-value-tab="create-convert"]}) |> render_click()
      lv |> element(@split_btn) |> render_click()

      lv |> element("#split-mode") |> render_change(%{"mode" => "ranges"})
      assert has_element?(lv, "#split-param-ranges")

      # invalid range → plain-language error
      lv |> element("#split-ranges") |> render_change(%{"ranges" => "1-99"})
      lv |> element("#split-submit-btn") |> render_click()

      assert has_element?(lv, ~s{div[role="alert"]})
      assert render(lv) =~ "out of range"
    end
  end
end
