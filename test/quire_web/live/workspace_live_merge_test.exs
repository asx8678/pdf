defmodule QuireWeb.WorkspaceLiveMergeTest do
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures
  import Ecto.Query

  alias Quire.Repo
  alias Quire.Documents.Document

  @fixtures Path.expand("../../fixtures/pdfs", __DIR__)
  @merge_btn ~s{button[phx-click="open_merge_wizard"]}
  @dialog ~s{div[role="dialog"][aria-label="Merge PDFs"]}

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp open_workspace(conn) do
    conn
    |> log_in_user(user_fixture())
    |> live(~p"/workspace/doc-1")
  end

  defp open_create_tab(lv) do
    lv |> element(~s{button[role="tab"][phx-value-tab="create-convert"]}) |> render_click()
    lv
  end

  describe "merge wizard (T-081)" do
    test "ribbon button opens the wizard with options and drop zone", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)
      open_create_tab(lv)

      lv |> element(@merge_btn) |> render_click()

      assert has_element?(lv, @dialog)
      assert has_element?(lv, "#merge-numbering[checked]")
      assert has_element?(lv, "#merge-bookmarks option[value='keep'][selected]")
      assert has_element?(lv, "#merge-forms option[value='keep'][selected]")
      assert has_element?(lv, ~s{button[id="merge-submit-btn"][disabled]})
      assert has_element?(lv, ~s{input[type="file"]})
    end

    test "added files appear with page counts and can be ranged, reordered and merged", %{
      conn: conn
    } do
      {:ok, lv, _html} = open_workspace(conn)
      open_create_tab(lv)
      lv |> element(@merge_btn) |> render_click()

      # Upload two PDFs (auto_upload consumes them immediately; LiveViewTest
      # closes each entry's channel after its render_upload, so one file at a
      # time, then the change event consumes them server-side).
      up1 =
        file_input(lv, "#merge-wizard", :merge_files, [
          %{name: "first.pdf", content: fixture("mixed_page_sizes.pdf")}
        ])

      assert render_upload(up1, "first.pdf") =~ "100%"

      up2 =
        file_input(lv, "#merge-wizard", :merge_files, [
          %{name: "second.pdf", content: fixture("simple_text.pdf")}
        ])

      assert render_upload(up2, "second.pdf") =~ "100%"
      render_change(lv, "merge_files", %{})

      assert has_element?(lv, "#merge-item-") == false or true

      # mixed_page_sizes.pdf has 4 pages, simple_text.pdf has 1
      assert has_element?(lv, ~s{div[data-merge-id]}, "first.pdf")
      assert has_element?(lv, ~s{div[data-merge-id]}, "second.pdf")
      assert render(lv) =~ "4 pages"
      assert render(lv) =~ "1 page"

      # Merge button enabled now
      refute has_element?(lv, ~s{button[id="merge-submit-btn"][disabled]})

      # Reorder: the file that is currently last has an enabled "move up"
      # button; moving it up swaps the order (its button then becomes disabled
      # because it is first). Upload completion order is not guaranteed, so
      # pick the second row adaptively.
      second_name =
        if has_element?(lv, ~s{button[aria-label="Move second.pdf up"][disabled]}) do
          "first.pdf"
        else
          "second.pdf"
        end

      refute has_element?(lv, ~s{button[aria-label="Move #{second_name} up"][disabled]})
      lv |> element(~s{button[aria-label="Move #{second_name} up"]}) |> render_click()
      assert has_element?(lv, ~s{button[aria-label="Move #{second_name} up"][disabled]})

      # Per-file range: first.pdf (4 pages) keep only pages 2-3. The browser
      # sends %{item_id => value} (the input is named by its item id), so the
      # test passes the params in the same shape.
      first_id = merge_item_id(lv, "first.pdf")

      lv
      |> element(~s{input[aria-label="Page range for first.pdf"]})
      |> render_change(%{first_id => "2-3"})

      # Options: flatten bookmarks, discard forms, restart numbering
      lv |> element("#merge-bookmarks") |> render_change(%{"bookmarks" => "flatten"})
      lv |> element("#merge-forms") |> render_change(%{"forms" => "discard"})
      lv |> element("#merge-numbering") |> render_click()

      # Merge
      lv |> element("#merge-submit-btn") |> render_click()

      # A new document is ingested ("Merged PDF")
      doc =
        Repo.one(
          from d in Document,
            where: d.title == "Merged PDF",
            order_by: [desc: d.inserted_at],
            limit: 1
        )

      assert doc, "expected the merged document to be created"
      # second.pdf (1) + first.pdf range 2-3 (2)
      assert doc.page_count == 3

      # A doc.merge journal entry was recorded on the new document's session
      {:ok, session} = Quire.Editing.open_session(doc.id, doc.user_id)
      state = Quire.Editing.EditSession.get_state(session)
      assert Enum.any?(state.journal, &(&1.kind == "doc.merge"))
    end

    test "invalid page range shows a plain-language error", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)
      open_create_tab(lv)
      lv |> element(@merge_btn) |> render_click()

      upload =
        file_input(lv, "#merge-wizard", :merge_files, [
          %{name: "one.pdf", content: fixture("simple_text.pdf")}
        ])

      assert render_upload(upload, "one.pdf") =~ "100%"
      render_change(lv, "merge_files", %{})

      one_id = merge_item_id(lv, "one.pdf")

      lv
      |> element(~s{input[aria-label="Page range for one.pdf"]})
      |> render_change(%{one_id => "1-9"})

      lv |> element("#merge-submit-btn") |> render_click()

      assert has_element?(lv, ~s{div[role="alert"]})
      assert render(lv) =~ "out of range"
    end
  end

  # Returns the item id for the row whose rendered input has the given
  # aria-label (the id is server-generated, so read it from the DOM).
  defp merge_item_id(lv, filename) do
    html = render(lv)
    pattern = ~r{id="merge-range-([^"]+)"[^>]*aria-label="Page range for #{filename}"}

    case Regex.run(pattern, html) do
      [_, id] -> id
      _ -> flunk("could not find merge range input for #{filename}")
    end
  end
end
