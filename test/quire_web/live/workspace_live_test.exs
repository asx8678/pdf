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

  describe "reset form (T-124)" do
    @reset_btn ~s{button[phx-click="reset_form"]}

    test "reset button is visible in the Forms tab and disabled when no form fields", %{
      conn: conn
    } do
      {:ok, lv, _html} = open_workspace(conn)
      select_tab(lv, "forms")

      assert has_element?(lv, @reset_btn)
      assert has_element?(lv, ~s{#{@reset_btn}[disabled]})
      assert has_element?(lv, ~s{#{@reset_btn}[aria-disabled="true"]})
      assert has_element?(lv, @reset_btn, "Reset Form")
    end
  end

  describe "auto-create fields (T-125)" do
    @auto_btn ~s{button[phx-click="auto_create_fields"]}
    @accept_btn ~s{button[phx-click="accept_detected_fields"]}
    @discard_btn ~s{button[phx-click="discard_detected_fields"]}

    @scanned Path.expand("../../fixtures/pdfs/scanned_300dpi.pdf", __DIR__)

    defp doc_fixture(user) do
      doc =
        %Quire.Documents.Document{
          id: Ecto.UUID.generate(),
          user_id: user.id,
          title: "scanned.pdf",
          page_count: 1
        }
        |> Quire.Repo.insert!()

      {:ok, ref} = Quire.Storage.put(File.read!(@scanned), name: "scanned.pdf")

      source_map = %{
        "storage_ref" => %{
          "adapter" => to_string(ref.adapter),
          "key" => ref.key,
          "name" => ref.name,
          "content_type" => ref.content_type,
          "byte_size" => ref.byte_size
        },
        "filename" => "scanned.pdf"
      }

      rev =
        %Quire.Documents.Revision{
          id: Ecto.UUID.generate(),
          document_id: doc.id,
          label: "Original upload",
          source: source_map
        }
        |> Quire.Repo.insert!()

      doc
      |> Ecto.Changeset.change(%{current_revision_id: rev.id})
      |> Quire.Repo.update!()
    end

    defp open_doc(conn, user, doc) do
      conn
      |> log_in_user(user)
      |> live(~p"/workspace/#{doc.id}")
    end

    defp latest_detect_job do
      import Ecto.Query

      Quire.Repo.one!(
        from j in Oban.Job,
          where: j.worker == "Quire.Workers.AutoCreateFieldsWorker",
          order_by: [desc: j.id],
          limit: 1
      )
    end

    test "button is visible and enabled on the Forms tab", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)
      select_tab(lv, "forms")

      assert has_element?(lv, @auto_btn)
      assert has_element?(lv, @auto_btn, "Auto-create fields")
      refute has_element?(lv, ~s{#{@auto_btn}[disabled]})
    end

    test "preview → accept creates a revision with real form fields", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      {:ok, lv, _html} = open_doc(conn, user, doc)
      select_tab(lv, "forms")

      lv |> element(@auto_btn) |> render_click()

      # A detection job was enqueued with an operation id
      job = latest_detect_job()
      op_id = job.args["operation_id"]
      assert is_binary(op_id)

      # Running indicator visible while the job is in flight
      assert render(lv) =~ "Detecting"

      # Simulate the worker's broadcast (Oban is manual in test)
      detections = %{
        total: 1,
        fields: [%{kind: :text, page_index: 0, rect: [72, 700, 250, 720]}]
      }

      Phoenix.PubSub.broadcast(
        Quire.PubSub,
        "document:#{doc.id}",
        {:auto_create_detections, op_id, detections}
      )

      render(lv)
      assert has_element?(lv, "#form-detection-preview")
      assert render(lv) =~ "Detected 1 field(s)"

      lv |> element(@accept_btn) |> render_click()

      assert render(lv) =~ "Created 1 form field(s)"
      refute has_element?(lv, "#form-detection-preview")

      # A new revision points at PDF bytes that carry the accepted field
      reloaded = Quire.Repo.reload!(doc)
      {:ok, rev} = Quire.Documents.current_revision(reloaded)
      assert rev.label =~ "Auto-create fields"
      assert rev.id == reloaded.current_revision_id

      {:ok, stored} = Quire.Storage.get(Quire.Documents.Revision.storage_ref(rev))
      {:ok, pdf_doc} = ExPdfium.open_blob(stored)
      {:ok, form_fields} = ExPdfium.form_fields(pdf_doc)
      assert length(form_fields) == 1
    end

    test "discard clears the preview without committing anything", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      {:ok, lv, _html} = open_doc(conn, user, doc)
      select_tab(lv, "forms")

      lv |> element(@auto_btn) |> render_click()
      job = latest_detect_job()
      op_id = job.args["operation_id"]

      detections = %{
        total: 2,
        fields: [
          %{kind: :text, page_index: 0, rect: [72, 700, 250, 720]},
          %{kind: :checkbox, page_index: 0, rect: [72, 610, 92, 630]}
        ]
      }

      Phoenix.PubSub.broadcast(
        Quire.PubSub,
        "document:#{doc.id}",
        {:auto_create_detections, op_id, detections}
      )

      render(lv)
      assert has_element?(lv, "#form-detection-preview")
      assert render(lv) =~ "Detected 2 field(s)"

      lv |> element(@discard_btn) |> render_click()

      refute has_element?(lv, "#form-detection-preview")
      assert render(lv) =~ "Detection discarded"

      # No new revision was created
      import Ecto.Query

      revisions =
        Quire.Repo.all(
          from r in Quire.Documents.Revision,
            where: r.document_id == ^doc.id
        )

      assert length(revisions) == 1
    end
  end

  describe "keyboard shortcuts (§8.5, T-033)" do
    test "the shell carries the keyboard hook and key bindings", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      assert has_element?(lv, ~s{div#workspace-shell[phx-hook][tabindex="-1"]})
    end

    test "? opens the shortcuts modal listing every category", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      refute has_element?(lv, "div[role='dialog'][aria-label='Keyboard shortcuts']")

      html = render_keydown(lv, "keydown", %{"key" => "?"})

      assert has_element?(lv, "div[role='dialog'][aria-label='Keyboard shortcuts']")

      for category <- ~w(File Edit Find Navigation View Other) do
        assert html =~ category
      end

      assert html =~ "<kbd"
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
        assert has_element?(lv, "input[aria-label='Page number'][value='1']")
        assert has_element?(lv, "span", "/ 1")
      end
    end
  end

  describe "bookmarks panel (T-047)" do
    @rail_button ~s{button[phx-click="toggle_panel"][phx-value-side="left"][phx-value-item="bookmarks"][aria-label="Bookmarks"]}

    test "the left rail toggles the bookmarks panel open and closed", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      refute has_element?(lv, "aside[aria-label='Bookmarks']")

      lv |> element(@rail_button) |> render_click()

      assert has_element?(lv, "aside[aria-label='Bookmarks']")
      assert has_element?(lv, "#bookmarks-panel")
      assert has_element?(lv, "#{@rail_button}[aria-pressed='true']")

      lv |> element(@rail_button) |> render_click()

      refute has_element?(lv, "aside[aria-label='Bookmarks']")
    end

    test "shows the empty state with an Add bookmark action", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      lv |> element(@rail_button) |> render_click()

      assert has_element?(lv, "#bookmarks-panel", "No bookmarks")
      assert has_element?(lv, "#bookmarks-panel button[aria-label='Add bookmark']")

      # The stub add_bookmark handler accepts the click without crashing
      lv |> element(~s{#bookmarks-panel button[aria-label="Add bookmark"]}) |> render_click()

      assert has_element?(lv, "#bookmarks-panel", "No bookmarks")
    end

    test "renders nested bookmarks with indentation and current-page highlight" do
      html =
        render_component(&QuireWeb.Chrome.BookmarksPanel.bookmarks_panel/1,
          bookmarks: [
            %{title: "Chapter 1", page: 1, children: [%{title: "Section 1.1", page: 3}]},
            %{title: "Chapter 2", page: 10}
          ],
          current_page: 3
        )

      assert html =~ "Chapter 1"
      assert html =~ "Section 1.1"
      assert html =~ "Chapter 2"
      assert html =~ ~s(phx-click="navigate_page")
      assert html =~ ~s(phx-value-page="3")
      assert html =~ "padding-left: 16px"
      # Exactly the current page's bookmark is highlighted
      assert html |> String.split("bg-accent/10 text-accent") |> length() == 2
    end

    test "clicking a bookmark fires navigate_page and updates the current page", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      render_click(lv, "navigate_page", %{"page" => "1"})

      assert has_element?(lv, "input[aria-label='Page number'][value='1']")
      assert has_element?(lv, "span", "/ 1")
    end
  end

  describe "scripting sandbox (pdf-fkm)" do
    test "scripting_enabled defaults to false in user_settings", %{conn: _conn} do
      user = Quire.AccountsFixtures.user_fixture()
      settings = Quire.Accounts.get_user_settings(user.id)
      refute settings.scripting_enabled, "scripting must default to off (§9.5)"
    end
  end

  describe "layers panel (T-050)" do
    @rail_button ~s{button[phx-click="toggle_panel"][phx-value-side="left"][phx-value-item="layers"][aria-label="Layers"]}

    test "the left rail toggles the layers panel open and closed", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      refute has_element?(lv, "aside[aria-label='Layers']")

      lv |> element(@rail_button) |> render_click()

      assert has_element?(lv, "aside[aria-label='Layers']")
      assert has_element?(lv, "#layers-panel")
      assert has_element?(lv, "#{@rail_button}[aria-pressed='true']")

      lv |> element(@rail_button) |> render_click()

      refute has_element?(lv, "aside[aria-label='Layers']")
    end

    test "shows the empty state when the document has no layers", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      lv |> element(@rail_button) |> render_click()

      assert has_element?(lv, "#layers-panel", "No layers")
      assert has_element?(lv, "#layers-panel", "optional content groups")
    end

    test "the stub toggle_layer handler accepts the event without crashing", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      lv |> element(@rail_button) |> render_click()
      render_click(lv, "toggle_layer", %{"name" => "Layer 1"})

      assert has_element?(lv, "#layers-panel", "No layers")
    end

    test "toggle_layer flips visibility locally; locked layers stay put" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          layers: [
            %{name: "Base map", visible: true, locked: false},
            %{name: "Survey", visible: true, locked: true}
          ]
        }
      }

      {:noreply, socket} =
        QuireWeb.WorkspaceLive.handle_event("toggle_layer", %{"name" => "Base map"}, socket)

      assert [%{name: "Base map", visible: false}, %{name: "Survey", visible: true}] =
               socket.assigns.layers

      {:noreply, socket} =
        QuireWeb.WorkspaceLive.handle_event("toggle_layer", %{"name" => "Survey"}, socket)

      assert [%{name: "Base map", visible: false}, %{name: "Survey", visible: true}] =
               socket.assigns.layers
    end

    test "renders layers with checked, dimmed and locked states" do
      html =
        render_component(&QuireWeb.Chrome.LayersPanel.layers_panel/1,
          layers: [
            %{name: "Base map", visible: true, locked: false},
            %{name: "Annotations", visible: false, locked: false},
            %{name: "Survey", visible: true, locked: true}
          ]
        )

      assert html =~ "3 layers"
      assert html =~ "Base map"
      assert html =~ ~s(phx-click="toggle_layer")
      assert html =~ ~s(phx-value-name="Annotations")

      # Visible layers get the accent checkbox; the hidden one doesn't
      assert html |> String.split("bg-accent border-accent") |> length() == 3
      assert html |> String.split("hero-check") |> length() == 3

      # The hidden layer's name is dimmed
      assert html =~ "text-gray-400 dark:text-gray-500"

      # Exactly the locked layer shows a lock icon
      assert html |> String.split("hero-lock-closed") |> length() == 2
    end
  end
end
