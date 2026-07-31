defmodule QuireWeb.WorkspaceLive.EditToolsTest do
  use QuireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Quire.Repo
  alias Quire.Documents.Document

  # Edit-tab ribbon controls introduced by T-094 (format painter + select
  # text). These are client-driven: the server hosts the ribbon buttons and
  # the event handlers that drive their enabled/active state.
  @add_text_btn ~s{button[phx-value-mode="add_text"]}
  @edit_text_btn ~s{button[phx-value-mode="edit_text"]}
  @edit_text_btn_acc ~s{button[phx-value-mode="edit_text"].text-accent}
  @format_painter_btn ~s{button[phx-click="toggle_format_painter"]}
  @select_text_btn ~s{button[phx-click="toggle_select_text"]}
  @select_text_btn_acc ~s{button[phx-click="toggle_select_text"].text-accent}

  defp open_edit_tab(conn) do
    {:ok, lv, _html} = open_workspace(conn)

    lv
    |> element(~s{button[role="tab"][phx-value-tab="edit"]})
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

  describe "Edit tab ribbon (T-094)" do
    test "renders Add text, Format painter and Select text with aria-labels", %{conn: conn} do
      lv = open_edit_tab(conn)

      assert has_element?(lv, @add_text_btn)
      assert has_element?(lv, @edit_text_btn)
      assert has_element?(lv, @format_painter_btn)
      assert has_element?(lv, @select_text_btn)

      # Icon-only controls must be labelled for keyboard accessibility
      # (Appendix E; plan3.md edit-tab controls).
      html = render(lv)
      assert html =~ "aria-label=\"Format painter"
      assert html =~ "aria-label=\"Select text mode"
    end

    test "format painter is disabled until an object is selected", %{conn: conn} do
      lv = open_edit_tab(conn)

      # Nothing selected -> disabled.
      assert has_element?(lv, ~s{#{@format_painter_btn}[aria-disabled="true"]})

      # Client reports an object selection -> the button becomes enabled.
      lv |> render_hook("edit_selection_changed", %{"selected" => true})

      assert has_element?(lv, ~s{#{@format_painter_btn}[aria-disabled="false"]})

      # Deselecting disables it again.
      lv |> render_hook("edit_selection_changed", %{"selected" => false})
      assert has_element?(lv, ~s{#{@format_painter_btn}[aria-disabled="true"]})
    end

    test "format painter is de-armed after the client applies a style", %{conn: conn} do
      lv = open_edit_tab(conn)

      lv |> render_hook("edit_selection_changed", %{"selected" => true})
      lv |> element(@format_painter_btn) |> render_click()

      # Client applied the copied format to the target -> single-shot de-arm.
      lv |> render_hook("format_painter_applied", %{})
      assert has_element?(lv, ~s{#{@format_painter_btn}[aria-disabled="true"]})
    end

    test "select text is exclusive with the Add/Edit tools", %{conn: conn} do
      lv = open_edit_tab(conn)

      # Turn on Edit text.
      lv |> element(@edit_text_btn) |> render_click()
      assert has_element?(lv, @edit_text_btn_acc)

      # Turn on Select text -> Edit text cleared (exclusive).
      lv |> element(@select_text_btn) |> render_click()
      assert has_element?(lv, @select_text_btn_acc)
      refute has_element?(lv, @edit_text_btn_acc)

      # Toggle Select text off.
      lv |> element(@select_text_btn) |> render_click()
      refute has_element?(lv, @select_text_btn_acc)
    end
  end

  # --- fixtures (mirrors workspace_live/stamp_placement_test.exs) ---

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
      title: "edit-tools-test.pdf"
    }
    |> Repo.insert!()
  end

  defp revision_fixture(doc) do
    {:ok, ex_doc} =
      ExPdfium.open(File.read!(Path.expand("../../../fixtures/pdfs/simple_text.pdf", __DIR__)))

    {:ok, pdf} = ExPdfium.save_to_bytes(ex_doc)

    {:ok, ref} =
      Quire.Storage.put(pdf, name: "edit-tools-test.pdf", content_type: "application/pdf")

    source = %{
      "storage_ref" => %{
        "adapter" => to_string(ref.adapter),
        "key" => ref.key,
        "name" => ref.name,
        "content_type" => ref.content_type,
        "byte_size" => ref.byte_size
      },
      "filename" => "edit-tools-test.pdf"
    }

    {:ok, rev} = Quire.Documents.create_revision(doc, label: "v1", source: source)

    {:ok, updated} =
      doc
      |> Ecto.Changeset.change(%{current_revision_id: rev.id, page_count: 1})
      |> Quire.Repo.update()

    updated
  end
end