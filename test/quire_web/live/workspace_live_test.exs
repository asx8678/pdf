defmodule QuireWeb.WorkspaceLiveTest do
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures

  @pill ~s{button[phx-click="toggle_view_mode"]}

  defp open_workspace(conn) do
    conn
    |> log_in_user(user_fixture())
    |> live(~p"/workspace/doc-1")
  end

  defp select_tab(lv, tab) do
    lv
    |> element(~s{button[role="tab"][phx-value-tab="#{tab}"]})
    |> render_click()
  end

  describe "view toggle pill" do
    test "is hidden on the default view tab", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      refute has_element?(lv, @pill)
    end

    test "shows on document-mutating tabs and hides on the rest", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      for tab <- ~w(edit comment secure forms esign ocr) do
        select_tab(lv, tab)
        assert has_element?(lv, @pill), "expected view toggle pill on the #{tab} tab"
      end

      for tab <- ~w(view create-convert fill-sign page translate) do
        select_tab(lv, tab)
        refute has_element?(lv, @pill), "expected no view toggle pill on the #{tab} tab"
      end
    end

    test "toggles between edit and preview with aria-label and dark variants", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)
      select_tab(lv, "edit")

      assert has_element?(lv, @pill, "Preview")
      assert has_element?(lv, "#{@pill}[aria-label='Switch to preview mode']")

      html = lv |> element(@pill) |> render_click()

      assert has_element?(lv, @pill, "Edit")
      assert has_element?(lv, "#{@pill}[aria-label='Switch to edit mode']")
      assert html =~ "dark:bg-gray-100"

      html = lv |> element(@pill) |> render_click()

      assert has_element?(lv, @pill, "Preview")
      assert has_element?(lv, "#{@pill}[aria-label='Switch to preview mode']")
      assert html =~ "dark:bg-gray-700"
    end

    test "keeps the mode when switching between pill tabs", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)
      select_tab(lv, "edit")
      lv |> element(@pill) |> render_click()

      select_tab(lv, "comment")

      assert has_element?(lv, @pill, "Edit")
    end
  end

  describe "keyboard shortcuts (§8.5, T-033)" do
    test "the shell carries the keyboard hook and key bindings", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      assert has_element?(
               lv,
               ~s{div#workspace-shell[phx-hook=".KeyboardShortcuts"][tabindex="-1"]}
             )
    end

    test "? opens the shortcuts modal listing every category", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      refute has_element?(lv, "div[role='dialog'][aria-label='Keyboard shortcuts']")

      html = render_keydown(lv, "keydown", %{"key" => "?"})

      assert has_element?(lv, "div[role='dialog'][aria-label='Keyboard shortcuts']")

      for category <- ~w(File Edit Find Navigation View Other) do
        assert html =~ category
      end

      assert html =~ "<kbd>"
      assert html =~ "Open document"
      assert html =~ "Zoom in"
      assert html =~ "Ribbon tab access keys"
    end

    test "Esc closes the shortcuts modal", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      render_keydown(lv, "keydown", %{"key" => "?"})
      assert has_element?(lv, "div[role='dialog'][aria-label='Keyboard shortcuts']")

      render_keydown(lv, "keydown", %{"key" => "Escape"})
      refute has_element?(lv, "div[role='dialog'][aria-label='Keyboard shortcuts']")
    end

    test "the modal close button closes the shortcuts modal", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      render_keydown(lv, "keydown", %{"key" => "?"})
      assert has_element?(lv, "div[role='dialog'][aria-label='Keyboard shortcuts']")

      lv
      |> element(
        ~s{div[role='dialog'][aria-label='Keyboard shortcuts'] button[aria-label='Close']}
      )
      |> render_click()

      refute has_element?(lv, "div[role='dialog'][aria-label='Keyboard shortcuts']")
    end

    test "Ctrl+= / Ctrl+- step zoom through the presets, Ctrl+0 resets", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      assert has_element?(lv, ~s{select[aria-label='Zoom level'] option[value='100'][selected]})

      render_keydown(lv, "keydown", %{"key" => "=", "ctrlKey" => true})
      assert has_element?(lv, ~s{select[aria-label='Zoom level'] option[value='125'][selected]})

      render_keydown(lv, "keydown", %{"key" => "-", "metaKey" => true})
      assert has_element?(lv, ~s{select[aria-label='Zoom level'] option[value='100'][selected]})

      render_keydown(lv, "keydown", %{"key" => "=", "ctrlKey" => true})
      render_keydown(lv, "keydown", %{"key" => "0", "ctrlKey" => true})
      assert has_element?(lv, ~s{select[aria-label='Zoom level'] option[value='100'][selected]})
    end

    test "zoom keys without a modifier leave the zoom alone", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      render_keydown(lv, "keydown", %{"key" => "="})
      assert has_element?(lv, ~s{select[aria-label='Zoom level'] option[value='100'][selected]})
    end

    test "page navigation keys stay within bounds on a one-page document", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      for key <- ~w(PageUp PageDown Home End) do
        render_keydown(lv, "keydown", %{"key" => key})
        assert has_element?(lv, "div[role='navigation'][aria-label='Page navigation']", "1 / 1")
      end
    end
  end
end
