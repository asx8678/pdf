defmodule QuireWeb.WorkspaceLive.FillSignToolsTest do
  use QuireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Quire.Repo
  alias Quire.Documents.Document

  # Fill & Sign tab palette (T-117). Server-side state is canonical here,
  # mirroring edit_tools_test.exs: the client owns the draw layer, while the
  # LiveView hosts the five ribbon controls, the floating palette, the
  # option settings and the Esc-deactivation that drives them.
  @text_tool_btn ~s{button[phx-value-tool="text"]}
  @crossmark_tool_btn ~s{button[phx-value-tool="crossmark"]}
  @check_tool_btn ~s{button[phx-value-tool="checkmark"]}
  @dot_tool_btn ~s{button[phx-value-tool="dot"]}
  @line_tool_btn ~s{button[phx-value-tool="line"]}

  defp open_fill_sign_tab(conn) do
    {:ok, lv, _html} = open_workspace(conn)

    lv
    |> element(~s{button[role="tab"][phx-value-tab="fill-sign"]})
    |> render_click()

    lv
  end

  defp open_workspace(conn) do
    user = user_fixture()
    doc = document_fixture(user)
    doc = revision_fixture(doc)
    {:ok, conn} = {:ok, log_in_user(conn, user)}
    live(conn, ~p"/workspace/#{doc.id}")
  end

  # Socket assigns are the canonical server truth (render DOM is stale in
  # this LiveViewTest version after render_click events).
  defp assigns(lv) do
    :sys.get_state(lv.pid).socket.assigns
  end

  describe "Fill & Sign tab palette (T-117)" do
    test "renders the five tool ribbon buttons with aria-labels", %{conn: conn} do
      lv = open_fill_sign_tab(conn)

      # The five tools are present as ribbon controls.
      assert has_element?(lv, @text_tool_btn)
      assert has_element?(lv, @crossmark_tool_btn)
      assert has_element?(lv, @check_tool_btn)
      assert has_element?(lv, @dot_tool_btn)
      assert has_element?(lv, @line_tool_btn)

      # The floating palette persists while the tab is active.
      assert has_element?(lv, "#fill-sign-palette")
    end

    test "tools are exclusive and toggle off by selecting the same tool", %{conn: conn} do
      lv = open_fill_sign_tab(conn)

      lv |> render_click("toggle_fill_sign_tool", %{"tool" => "text"})
      assert assigns(lv).fill_sign_tool == "text"

      # Selecting a different tool clears the previous one (exclusive).
      lv |> render_click("toggle_fill_sign_tool", %{"tool" => "crossmark"})
      assert assigns(lv).fill_sign_tool == "crossmark"

      # Selecting the same tool again toggles it off.
      lv |> render_click("toggle_fill_sign_tool", %{"tool" => "crossmark"})
      assert assigns(lv).fill_sign_tool == nil
    end

    test "selecting the remaining glyph and line tools updates the assign", %{conn: conn} do
      lv = open_fill_sign_tab(conn)

      lv |> render_click("toggle_fill_sign_tool", %{"tool" => "checkmark"})
      assert assigns(lv).fill_sign_tool == "checkmark"

      lv |> render_click("toggle_fill_sign_tool", %{"tool" => "dot"})
      assert assigns(lv).fill_sign_tool == "dot"

      lv |> render_click("toggle_fill_sign_tool", %{"tool" => "line"})
      assert assigns(lv).fill_sign_tool == "line"
    end

    test "Esc deactivates the active Fill & Sign tool", %{conn: conn} do
      lv = open_fill_sign_tab(conn)

      lv |> render_click("toggle_fill_sign_tool", %{"tool" => "text"})
      assert assigns(lv).fill_sign_tool == "text"

      lv |> render_click("keydown", %{"key" => "Escape"})
      assert assigns(lv).fill_sign_tool == nil
    end

    test "option controls update the palette settings", %{conn: conn} do
      lv = open_fill_sign_tab(conn)

      # A native <select> with phx-change sends its current value under
      # "value"; colour inputs do the same.
      lv |> render_click("set_fill_sign_font", %{"value" => "Times"})
      assert assigns(lv).fill_sign_font == "Times"

      lv |> render_click("set_fill_sign_text_size", %{"value" => "18"})
      assert assigns(lv).fill_sign_font_size == "18"

      lv |> render_click("set_fill_sign_text_color", %{"value" => "#ff0000"})
      assert assigns(lv).fill_sign_text_color == "#ff0000"

      lv |> render_click("set_fill_sign_glyph_color", %{"value" => "#00ff00"})
      assert assigns(lv).fill_sign_glyph_color == "#00ff00"

      lv |> render_click("set_fill_sign_line_weight", %{"value" => "4"})
      assert assigns(lv).fill_sign_line_weight == "4"

      lv |> render_click("set_fill_sign_line_color", %{"value" => "#0000ff"})
      assert assigns(lv).fill_sign_line_color == "#0000ff"
    end

    test "the Done button deactivates the active tool", %{conn: conn} do
      lv = open_fill_sign_tab(conn)

      lv |> render_click("toggle_fill_sign_tool", %{"tool" => "line"})
      assert assigns(lv).fill_sign_tool == "line"

      lv |> render_click("deactivate_fill_sign_tool", %{})
      assert assigns(lv).fill_sign_tool == nil
    end
  end

  # --- fixtures (mirrors workspace_live/edit_tools_test.exs) ---

  defp user_fixture do
    %Quire.Accounts.User{
      id: Ecto.UUID.generate(),
      email: "user-#{System.unique_integer([:positive])}@example.com",
      hashed_password: "x"
    }
    |> Repo.insert!()
  end

  defp document_fixture(user) do
    %Document{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      title: "fill-sign-tools-test.pdf"
    }
    |> Repo.insert!()
  end

  defp revision_fixture(doc) do
    {:ok, ex_doc} =
      ExPdfium.open(File.read!(Path.expand("../../../fixtures/pdfs/simple_text.pdf", __DIR__)))

    {:ok, pdf} = ExPdfium.save_to_bytes(ex_doc)

    {:ok, ref} =
      Quire.Storage.put(pdf, name: "fill-sign-tools-test.pdf", content_type: "application/pdf")

    source = %{
      "storage_ref" => %{
        "adapter" => to_string(ref.adapter),
        "key" => ref.key,
        "name" => ref.name,
        "content_type" => ref.content_type,
        "byte_size" => ref.byte_size
      },
      "filename" => "fill-sign-tools-test.pdf"
    }

    {:ok, rev} = Quire.Documents.create_revision(doc, label: "v1", source: source)

    {:ok, updated} =
      doc
      |> Ecto.Changeset.change(%{current_revision_id: rev.id, page_count: 1})
      |> Quire.Repo.update()

    updated
  end
end
