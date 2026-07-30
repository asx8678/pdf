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
end
