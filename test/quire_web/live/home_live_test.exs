defmodule QuireWeb.HomeLiveTest do
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @tile_titles [
    "Open PDF",
    "Clipboard to PDF",
    "Merge files",
    "Convert to PDF",
    "PDF to Word",
    "PDF to Excel",
    "Add comment",
    "Protect your PDF",
    "Batch",
    "Customize"
  ]

  defp open_home(conn), do: live(conn, ~p"/")

  describe "tile grid" do
    test "renders all ten tool tiles", %{conn: conn} do
      {:ok, _lv, html} = open_home(conn)

      for title <- @tile_titles do
        assert html =~ title
      end
    end

    test "tiles use design tokens and dark variants", %{conn: conn} do
      {:ok, _lv, html} = open_home(conn)

      assert html =~ "bg-chrome-white dark:bg-gray-800"
      assert html =~ "border-chrome-border dark:border-gray-600"
      assert html =~ "bg-accent/10"
      assert html =~ "text-accent"
    end
  end

  describe "empty state" do
    test "shows the drop zone copy when there are no recent documents", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)

      assert has_element?(lv, "div.border-dashed", "Drop a PDF here or choose a tool to start")
    end

    test "recent panel shows its own empty placeholder", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)

      assert has_element?(lv, "p", "No recent documents")
    end
  end

  describe "floating action buttons" do
    test "renders feedback and support FABs fixed bottom-right", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)

      assert has_element?(lv, "div.fixed.bottom-6.right-6 button[aria-label='Feedback']")
      assert has_element?(lv, "div.fixed.bottom-6.right-6 button[aria-label='Support']")
    end
  end

  describe "customize modal" do
    test "opens from the Customize tile and closes again", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)

      refute has_element?(lv, "div[role='dialog']")

      lv
      |> element("div[phx-click='open_customize']", "Customize")
      |> render_click()

      assert has_element?(lv, "div[role='dialog'][aria-label='Customize tiles']")
      assert has_element?(lv, "div[role='dialog'] p", "Show or hide tiles on the home screen")

      lv
      |> element("div[role='dialog'] button[aria-label='Close']")
      |> render_click()

      refute has_element?(lv, "div[role='dialog']")
    end

    test "hides a tile from the grid and shows it again", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)

      lv
      |> element("div[phx-click='open_customize']", "Customize")
      |> render_click()

      lv
      |> element("button[aria-label='Hide Batch']")
      |> render_click()

      refute lv |> element("div[role='dialog']") |> render() =~
               ~r/<p class="text-xs font-medium[^"]*">\s*Batch/

      grid_html = render(lv)
      refute grid_html =~ "Chain operations on files"

      lv
      |> element("button[aria-label='Show Batch']")
      |> render_click()

      assert render(lv) =~ "Chain operations on files"
    end

    test "never offers to hide the Customize tile itself", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)

      lv
      |> element("div[phx-click='open_customize']", "Customize")
      |> render_click()

      refute has_element?(lv, "button[aria-label='Hide Customize']")
    end
  end

  describe "recent panel controls" do
    test "sort select updates the sort assign", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)

      lv
      |> element("form[phx-change='sort_changed']")
      |> render_change(%{"sort_by" => "name"})

      assert has_element?(lv, "select[name='sort_by'] option[value='name'][selected]")
    end

    test "rejects an unknown sort value", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)

      lv
      |> element("form[phx-change='sort_changed']")
      |> render_change(%{"sort_by" => "bogus"})

      assert has_element?(lv, "select[name='sort_by'] option[value='last_opened'][selected]")
    end

    test "grid/list toggle switches the view mode", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)

      lv |> element("button[aria-label='List view']") |> render_click()
      assert has_element?(lv, "button[aria-label='List view'].bg-gray-100")

      lv |> element("button[aria-label='Grid view']") |> render_click()
      assert has_element?(lv, "button[aria-label='Grid view'].bg-gray-100")
    end
  end
end
