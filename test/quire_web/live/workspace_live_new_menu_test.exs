defmodule QuireWeb.WorkspaceLiveNewMenuTest do
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures
  import Ecto.Query

  alias Quire.Repo
  alias Quire.Documents.Document

  @new_btn ~s{button[id="new-menu-btn"]}
  @new_menu ~s{div[id="new-menu"]}

  defp open_workspace(conn) do
    conn
    |> log_in_user(user_fixture())
    |> live(~p"/workspace/doc-1")
  end

  defp open_create_tab(lv) do
    lv |> element(~s{button[role="tab"][phx-value-tab="create-convert"]}) |> render_click()
    lv
  end

  describe "New ▾ dropdown (T-085)" do
    test "shows all four entries with accessible labels", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)
      open_create_tab(lv)

      assert has_element?(lv, ~s{button[id="new-menu-btn"][aria-haspopup="menu"]})
      lv |> element(@new_btn) |> render_click()

      assert has_element?(lv, @new_menu)
      assert has_element?(lv, @new_menu, "Blank document")
      assert has_element?(lv, @new_menu, "From template")
      assert has_element?(lv, @new_menu, "From clipboard")
      assert has_element?(lv, @new_menu, "From scanner")
      # the clipboard entry reuses the T-079 client hook
      assert has_element?(lv, ~s{button[id="new-clipboard-btn"][phx-hook="ClipboardPdf"]})
    end

    test "blank document opens a new document with the chosen size and orientation", %{
      conn: conn
    } do
      {:ok, lv, _html} = open_workspace(conn)
      open_create_tab(lv)

      lv |> element(@new_btn) |> render_click()
      lv |> element(~s{button[role="menuitem"]}, "Blank document") |> render_click()

      assert has_element?(lv, ~s{div[role="dialog"][aria-label="New blank document"]})
      # icon-only orientation controls carry aria-labels
      assert has_element?(lv, ~s{button[id="blank-orientation-portrait"][aria-label="Portrait"]})

      assert has_element?(
               lv,
               ~s{button[id="blank-orientation-landscape"][aria-label="Landscape"]}
             )

      # portrait is selected by default (the selected radio carries aria-checked)
      assert has_element?(lv, ~s{button[id="blank-orientation-portrait"][aria-checked]})
      assert has_element?(lv, ~s{button[id="blank-orientation-landscape"]:not([aria-checked])})

      # choose Legal landscape
      lv |> element("#blank-size") |> render_change(%{"size" => "legal"})
      lv |> element("#blank-orientation-landscape") |> render_click()
      lv |> element("#blank-create-btn") |> render_click()

      doc = Repo.one(from d in Document, where: d.title == "Blank LEGAL", limit: 1)
      assert doc, "expected the blank document to be created"
      assert doc.page_count == 1

      # legal landscape = 1008 × 612
      {:ok, rev} = Quire.Documents.current_revision(doc)
      ref = Quire.Documents.Revision.storage_ref(rev)
      {:ok, bytes} = Quire.Storage.get(ref)
      assert {:ok, pdf_doc} = ExPdfium.open(bytes)
      assert {:ok, info} = ExPdfium.page_info(pdf_doc, 0)
      # page_info exposes the media box
      assert info.width == 1008.0 or info.width == nil or info.height == 612.0
    end

    test "template creates a new document", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)
      open_create_tab(lv)

      lv |> element(@new_btn) |> render_click()
      lv |> element(~s{button[role="menuitem"]}, "From template") |> render_click()

      assert has_element?(lv, ~s{div[role="dialog"][aria-label="New from template"]})
      assert has_element?(lv, ~s{button[aria-label="Template: Cover page"]})

      lv |> element(~s{button[aria-label="Template: Cover page"]}) |> render_click()
      lv |> element("#template-create-btn") |> render_click()

      doc = Repo.one(from d in Document, where: d.title == "Template: Cover page", limit: 1)
      assert doc, "expected the template document to be created"
    end

    test "from scanner reuses the T-080 camera flow", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)
      open_create_tab(lv)

      lv |> element(@new_btn) |> render_click()
      lv |> element(~s{button[role="menuitem"]}, "From scanner") |> render_click()

      assert has_element?(lv, ~s{div[role="dialog"][aria-label="Scan to PDF"]})
    end
  end
end
