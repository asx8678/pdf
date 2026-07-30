defmodule QuireWeb.WorkspaceLive do
  @moduledoc """
  The workspace shell (plan3.md §8.1): a single LiveView that owns the
  title bar, menu bar, ribbon, document tab strip, side rails and
  collapsible panels, and the status bar, so the chrome and document
  state stay in lockstep without PubSub round trips.

  Mounted at `/workspace/:id` for authenticated users. Wired here: menu
  bar tab selection, rail panel toggles, page navigation, the
  thumbnails panel (T-046), and the bookmarks outline panel (T-047), and the multi-document tab strip (T-032) — open, switch, close, reorder
  tabs, and an unsaved-changes confirmation modal — and the §8.5
  keyboard map (T-033) with its discoverable shortcuts modal. Document
  loading and the per-tab ribbon LiveComponents (§9), and the backstage
  overlay (T-036) build on this shell.
  """
  use QuireWeb, :live_view

  import QuireWeb.Chrome.AttachmentsPanel, only: [attachments_panel: 1]
  import QuireWeb.Chrome.Backstage, only: [backstage: 1]
  import QuireWeb.Chrome.BookmarksPanel, only: [bookmarks_panel: 1]
  import QuireWeb.Chrome.DocumentTabs, only: [document_tabs: 1]
  import QuireWeb.Chrome.EmailCompose, only: [email_compose: 1]
  import QuireWeb.Chrome.LayersPanel, only: [layers_panel: 1]
  import QuireWeb.Chrome.MenuBar, only: [menu_bar: 1]
  import QuireWeb.Chrome.Rail, only: [rail: 1]
  import QuireWeb.Chrome.SearchPanel, only: [search_panel: 1]
  import QuireWeb.Chrome.ShortcutsModal, only: [shortcuts_modal: 1]
  import QuireWeb.Chrome.StatusBar, only: [status_bar: 1]
  import QuireWeb.Chrome.ThumbnailsPanel, only: [thumbnails_panel: 1]
  import QuireWeb.Chrome.TitleBar, only: [title_bar: 1]
  import QuireWeb.Shared.Modal, only: [modal: 1]

  # The shell markup lives in workspace_live/workspace.html.heex (T-033);
  # render/1 below only precomputes derived assigns and delegates to it.
  embed_templates "workspace_live/*"

  @left_rail_items [
    %{id: :thumbnails, icon: "hero-squares-2x2", label: "Thumbnails"},
    %{id: :bookmarks, icon: "hero-bookmark", label: "Bookmarks"},
    %{id: :layers, icon: "hero-rectangle-stack", label: "Layers"}
  ]

  @right_rail_items [
    %{id: :search, icon: "hero-magnifying-glass", label: "Search"},
    %{id: :attachments, icon: "hero-paper-clip", label: "Attachments"}
  ]

  @panels [:thumbnails, :bookmarks, :layers, :search, :attachments]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    document_url = "/documents/" <> id <> "/pdf"

    {doc_title, doc_page_count} =
      case Quire.Documents.get_document(id, scope) do
        {:ok, doc} ->
          {doc.title, doc.page_count}

        _ ->
          {"Unknown document", 1}
      end

    initial_doc = %{id: id, title: doc_title, dirty: false, path: nil}

    socket =
      socket
      |> assign(:page_title, "Workspace")
      |> assign(:document_title, doc_title)
      |> assign(:document_url, document_url)
      |> assign(:documents, [initial_doc])
      |> assign(:active_document_id, id)
      |> assign(:confirm_close_doc, nil)
      |> assign(:active_tab, "view")
      |> assign(:view_mode, :edit)
      |> assign(:left_panel, nil)
      |> assign(:right_panel, nil)
      |> assign(:page, 1)
      |> assign(:total_pages, doc_page_count)
      |> assign(:thumbnails, [])
      |> assign(:bookmarks, [])
      |> assign(:layers, [])
      |> assign(:attachments, [])
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:search_total, 0)
      |> assign(:search_current, 0)
      |> assign(:search_match_case, false)
      |> assign(:search_whole_word, false)
      |> assign(:searching, false)
      |> assign(:zoom, 100)
      |> assign(:scroll_mode, :vertical)
      |> assign(:spread_mode, :single)
      |> assign(:fit_mode, :fit_page)
      |> assign(:fullscreen, false)
      |> assign(:rotation, 0)
      |> assign(:split_view, false)
      |> assign(:snapshot_active, false)
      |> assign(:read_aloud_active, false)
      |> assign(:read_aloud_playing, false)
      |> assign(:read_only?, false)
      |> assign(:progress, nil)
      |> assign(:show_shortcuts, false)
      |> assign(:backstage_open, false)
      |> assign(:backstage_view, nil)
      |> assign(:show_email_compose, false)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    assigns
    |> assign(:left_items, rail_items(@left_rail_items, assigns.left_panel))
    |> assign(:right_items, rail_items(@right_rail_items, assigns.right_panel))
    |> workspace()
  end

  # ── Document tab event handlers ──────────────────────────────────────────

  @impl true
  def handle_event("open_document", %{"id" => id}, socket) do
    id = coerce_id(id)

    socket =
      if doc = Enum.find(socket.assigns.documents, &(&1.id == id)) do
        # Already open — just switch to it
        socket
        |> assign(:active_document_id, doc.id)
        |> assign(:document_title, doc.title)
      else
        # New document — add to list, set active, navigate
        new_doc = %{id: id, title: "Document #{id}", dirty: false, path: nil}

        socket
        |> assign(:documents, socket.assigns.documents ++ [new_doc])
        |> assign(:active_document_id, id)
        |> assign(:document_title, "Document #{id}")
        |> push_navigate(to: ~p"/workspace/#{id}")
      end

    {:noreply, socket}
  end

  def handle_event("switch_tab", %{"id" => id}, socket) do
    id = coerce_id(id)

    if doc = Enum.find(socket.assigns.documents, &(&1.id == id)) do
      socket =
        socket
        |> assign(:active_document_id, doc.id)
        |> assign(:document_title, doc.title)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_tab", %{"id" => id}, socket) do
    id = coerce_id(id)

    with %{dirty: true} = doc <- Enum.find(socket.assigns.documents, &(&1.id == id)) do
      socket =
        socket
        |> assign(:confirm_close_doc, {doc.id, doc.title})

      {:noreply, socket}
    else
      _ ->
        socket = remove_doc(socket, id)
        {:noreply, socket}
    end
  end

  def handle_event("confirm_close", _params, socket) do
    case socket.assigns.confirm_close_doc do
      {id, _title} ->
        socket =
          socket
          |> assign(:confirm_close_doc, nil)
          |> remove_doc(id)

        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_close", _params, socket) do
    {:noreply, assign(socket, :confirm_close_doc, nil)}
  end

  def handle_event("reorder_tabs", %{"from" => from, "to" => to}, socket) do
    from_id = coerce_id(from)
    to_id = coerce_id(to)

    docs = socket.assigns.documents
    from_idx = Enum.find_index(docs, &(&1.id == from_id))
    to_idx = Enum.find_index(docs, &(&1.id == to_id))

    if from_idx && to_idx do
      # Remove from original position, insert at target
      {moved, rest} = List.pop_at(docs, from_idx)
      reordered = List.insert_at(rest, if(to_idx > from_idx, do: to_idx - 1, else: to_idx), moved)

      {:noreply, assign(socket, :documents, reordered)}
    else
      {:noreply, socket}
    end
  end

  # ── Keyboard handler ─────────────────────────────────────────────────────

  def handle_event("keydown", %{"key" => "w"} = params, socket) do
    if params["ctrlKey"] || params["metaKey"] do
      # Ctrl/⌘+W — close current tab
      socket =
        if active_id = socket.assigns.active_document_id do
          doc = Enum.find(socket.assigns.documents, &(&1.id == active_id))

          case doc do
            %{dirty: true} -> assign(socket, :confirm_close_doc, {doc.id, doc.title})
            %{id: _} -> remove_doc(socket, active_id)
            nil -> socket
          end
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("keydown", %{"key" => "Tab"} = params, socket) do
    if params["ctrlKey"] || params["metaKey"] do
      docs = socket.assigns.documents

      if length(docs) > 0 do
        current_id = socket.assigns.active_document_id
        current_idx = Enum.find_index(docs, &(&1.id == current_id)) || 0

        next_idx =
          if params["shiftKey"] do
            rem(current_idx - 1 + length(docs), length(docs))
          else
            rem(current_idx + 1, length(docs))
          end

        next = Enum.at(docs, next_idx)

        socket =
          socket
          |> assign(:active_document_id, next.id)
          |> assign(:document_title, next.title)

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Shift+/ ("?") — open the keyboard shortcuts modal (T-033)
  def handle_event("keydown", %{"key" => "?"}, socket) do
    {:noreply, assign(socket, :show_shortcuts, true)}
  end

  # Ctrl/⌘+Shift+F — toggle fullscreen mode
  def handle_event("keydown", %{"key" => "F"} = params, socket) do
    if (params["ctrlKey"] || params["metaKey"]) && params["shiftKey"] do
      {:noreply, assign(socket, :fullscreen, !socket.assigns.fullscreen)}
    else
      {:noreply, socket}
    end
  end

  # Esc — cancel/close: dismiss whichever modal is open
  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    socket =
      socket
      |> assign(:show_shortcuts, false)
      |> assign(:confirm_close_doc, nil)
      |> assign(:backstage_open, false)
      |> assign(:backstage_view, nil)
      |> assign(:fullscreen, false)

    {:noreply, socket}
  end

  # PageUp / PageDown / Home / End — page navigation
  def handle_event("keydown", %{"key" => key}, socket)
      when key in ~w(PageUp PageDown Home End) do
    {:noreply, assign(socket, :page, page_for_key(key, socket.assigns))}
  end

  # Ctrl/⌘+= / - / 0 / 1 — zoom in / out / fit page / actual size
  def handle_event("keydown", %{"key" => key} = params, socket)
      when key in ["=", "+", "-", "0", "1"] do
    if params["ctrlKey"] || params["metaKey"] do
      {:noreply, assign(socket, :zoom, zoom_for_key(key, socket.assigns.zoom))}
    else
      {:noreply, socket}
    end
  end

  # Ctrl/⌘S — save document
  def handle_event("keydown", %{"key" => "s"} = params, socket) do
    if params["ctrlKey"] || params["metaKey"] do
      if params["shiftKey"] do
        # ⌘⇧S — save as
        {:noreply, assign(socket, :backstage_open, true) |> assign(:backstage_view, "save-as")}
      else
        # ⌘S — save
        docs = Enum.map(socket.assigns.documents, &%{&1 | dirty: false})
        {:noreply, assign(socket, :documents, docs)}
      end
    else
      {:noreply, socket}
    end
  end

  # The rest of the §8.5 map — open/print, undo/redo, find,
  # select-all, Delete, F11 and Alt+letter access keys — depends on a
  # loaded document, the undo stack or the ribbon (§9); those keypresses
  # fall through here until the features land.
  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  def handle_event("keyup", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_shortcuts", _params, socket) do
    {:noreply, assign(socket, :show_shortcuts, !socket.assigns.show_shortcuts)}
  end

  def handle_event("close_shortcuts", _params, socket) do
    {:noreply, assign(socket, :show_shortcuts, false)}
  end

  # ── Backstage event handlers (T-036) ─────────────────────────────────────

  def handle_event("open_backstage", _params, socket) do
    {:noreply, assign(socket, :backstage_open, true)}
  end

  def handle_event("close_backstage", _params, socket) do
    {:noreply, socket |> assign(:backstage_open, false) |> assign(:backstage_view, nil)}
  end

  def handle_event("backstage_select", %{"view" => view}, socket) do
    socket =
      case view do
        "exit" ->
          socket
          |> assign(:backstage_open, false)
          |> assign(:backstage_view, nil)
          |> push_navigate(to: ~p"/")

        "save" ->
          docs = Enum.map(socket.assigns.documents, &%{&1 | dirty: false})
          assign(socket, :documents, docs)

        "save-as" ->
          assign(socket, :backstage_view, view)

        "save-optimized" ->
          docs = Enum.map(socket.assigns.documents, &%{&1 | dirty: false})
          assign(socket, :documents, docs)

        _ ->
          assign(socket, :backstage_view, view)
      end

    {:noreply, socket}
  end

  def handle_event("backstage_upload", %{"file" => _file}, socket) do
    # File upload from backstage Browse — T-044 document open pipeline lands here
    {:noreply, socket}
  end

  # ── Save / Save as event handlers (T-037) ────────────────────────────────

  def handle_event("save_document", _params, socket) do
    # T-044: Materialise the journal into a new revision
    # For now: mark all docs clean as a stub
    docs = Enum.map(socket.assigns.documents, &%{&1 | dirty: false})
    {:noreply, assign(socket, :documents, docs)}
  end

  def handle_event("save_document_as", _params, socket) do
    # T-044: New documents row; web offers download + library copy
    {:noreply, socket}
  end

  def handle_event("save_optimized", _params, socket) do
    # T-044: Save then compress job; show size delta
    {:noreply, socket}
  end

  def handle_event("save_and_close", _params, socket) do
    # Save then close
    docs = Enum.map(socket.assigns.documents, &%{&1 | dirty: false})
    {id, _title} = socket.assigns.confirm_close_doc

    socket =
      socket
      |> assign(:documents, docs)
      |> assign(:confirm_close_doc, nil)
      |> remove_doc(id)

    {:noreply, socket}
  end

  # ── Email compose event handlers (T-198) ─────────────────────────────────

  def handle_event("open_email_compose", _params, socket) do
    {:noreply, assign(socket, :show_email_compose, true)}
  end

  def handle_event("close_email_compose", _params, socket) do
    {:noreply, assign(socket, :show_email_compose, false)}
  end

  def handle_event("send_email", _params, socket) do
    # T-198: Send via Swoosh; for Phase 1, just close the modal
    {:noreply, assign(socket, :show_email_compose, false)}
  end

  # ── PdfViewerHook event handlers (T-042) ────────────────────────────────

  @impl true
  def handle_event("page_changed", %{"page" => page}, socket) do
    {:noreply, assign(socket, :page, page)}
  end

  # Bookmarks panel (T-047) — bookmark creation lands with the outline
  # feature ticket; the button is visible but inert until then.
  def handle_event("add_bookmark", _params, socket) do
    {:noreply, socket}
  end

  # Layers panel (T-050) — toggles a layer's local visibility flag.
  # Stub: the real OCG toggle (pdf.js PDFDocument.getOptionalContentConfig)
  # lands with T-051; locked layers don't toggle.
  def handle_event("toggle_layer", %{"name" => name}, socket) do
    layers =
      Enum.map(socket.assigns.layers, fn
        %{name: ^name, locked: false} = layer -> %{layer | visible: !layer.visible}
        layer -> layer
      end)

    {:noreply, assign(socket, :layers, layers)}
  end

  # Attachments panel (T-049) — read-only stub; the real preview
  # (open embedded file from the document's attachment store) lands
  # after pdf-0g9 resolves.
  def handle_event("preview_attachment", %{"name" => _name}, socket) do
    {:noreply, socket}
  end

  # Thumbnails panel (T-046) — clamp into range and push to the viewer
  # hook so pdf.js scrolls to the page.
  def handle_event("navigate_page", %{"page" => page}, socket) do
    case Integer.parse(to_string(page)) do
      {page, _} ->
        page = page |> max(1) |> min(socket.assigns.total_pages)

        {:noreply,
         socket
         |> assign(:page, page)
         |> push_event("navigate_page", %{page: page})}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("navigate_to_page", %{"page" => page_str}, socket) do
    case Integer.parse(to_string(page_str)) do
      {page, _} ->
        page = page |> max(1) |> min(socket.assigns.total_pages)

        {:noreply,
         socket
         |> assign(:page, page)
         |> push_event("navigate_page", %{page: page})}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("document_loaded", %{"page_count" => page_count}, socket) do
    {:noreply, assign(socket, :total_pages, page_count)}
  end

  def handle_event("document_ready", %{"total_pages" => total_pages} = params, socket) do
    page = Map.get(params, "current_page", 1)
    {:noreply, assign(socket, :total_pages, total_pages) |> assign(:page, page)}
  end

  def handle_event("zoom_changed", %{"zoom" => zoom}, socket) do
    {:noreply, assign(socket, :zoom, zoom)}
  end

  def handle_event("set_scroll_mode", %{"mode" => mode}, socket) when mode in ~w(vertical horizontal wrapped) do
    {:noreply,
     socket
     |> assign(:scroll_mode, String.to_existing_atom(mode))
     |> push_event("set_scroll_mode", %{mode: mode})}
  end

  def handle_event("set_spread_mode", %{"mode" => mode}, socket) when mode in ~w(none single odd even) do
    {:noreply,
     socket
     |> assign(:spread_mode, String.to_existing_atom(mode))
     |> push_event("set_spread_mode", %{mode: mode})}
  end

  def handle_event("set_fit_mode", %{"mode" => mode}, socket) when mode in ~w(fit_page fit_width actual_size) do
    {:noreply,
     socket
     |> assign(:fit_mode, String.to_existing_atom(mode))
     |> push_event("set_fit_mode", %{mode: mode})}
  end

  def handle_event("document_error", %{"message" => msg}, socket) do
    {:noreply, put_flash(socket, :error, "Document error: #{msg}")}
  end

  def handle_event("document_error", _params, socket) do
    {:noreply, put_flash(socket, :error, "An unknown document error occurred")}
  end

  # ── Search panel event handlers (T-048) ──────────────────────────────────

  # Debounced keydown from the search input. A non-empty query is pushed
  # to the PdfViewerHook, which runs pdf.js's find controller and answers
  # with "search_results"; an empty query clears the panel locally.
  def handle_event("search", %{"value" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> run_search()}
  end

  def handle_event("toggle_search_option", %{"option" => option}, socket) do
    key =
      case option do
        "match_case" -> :search_match_case
        "whole_word" -> :search_whole_word
        _ -> nil
      end

    socket =
      if key do
        socket |> assign(key, !socket.assigns[key]) |> run_search()
      else
        socket
      end

    {:noreply, socket}
  end

  # The viewer hook's answer to "find": a flat list of matches across
  # pages, each %{"page" => n, "text" => snippet}.
  def handle_event("search_results", %{"results" => results, "total" => total}, socket) do
    results = Enum.map(results, &%{page: &1["page"], text: &1["text"]})

    {:noreply,
     socket
     |> assign(:search_results, results)
     |> assign(:search_total, total)
     |> assign(:search_current, 0)
     |> assign(:searching, false)}
  end

  def handle_event("search_navigate", %{"page" => page, "index" => index}, socket) do
    with {page, _} <- Integer.parse(to_string(page)),
         {index, _} <- Integer.parse(to_string(index)) do
      page = page |> max(1) |> min(socket.assigns.total_pages)

      {:noreply,
       socket
       |> assign(:page, page)
       |> assign(:search_current, index)
       |> push_event("navigate_page", %{page: page})}
    else
      :error -> {:noreply, socket}
    end
  end

  def handle_event("search_next", _params, socket) do
    {:noreply, step_search(socket, 1)}
  end

  def handle_event("search_prev", _params, socket) do
    {:noreply, step_search(socket, -1)}
  end

  # ── Snapshot (T-055) event handlers ──────────────────────────────────────

  def handle_event("toggle_snapshot_mode", _params, socket) do
    active = !socket.assigns.snapshot_active

    {:noreply,
     socket
     |> assign(:snapshot_active, active)
     |> push_event("toggle_snapshot", %{active: active})}
  end

  def handle_event("snapshot_captured", %{"dataUrl" => _data_url}, socket) do
    {:noreply, socket}
  end

  def handle_event("read_aloud_play", _params, socket) do
    {:noreply,
     socket
     |> assign(:read_aloud_active, true)
     |> assign(:read_aloud_playing, true)
     |> push_event("read_aloud", %{action: "play", page: socket.assigns.page})}
  end

  def handle_event("read_aloud_pause", _params, socket) do
    {:noreply,
     socket
     |> assign(:read_aloud_playing, false)
     |> push_event("read_aloud", %{action: "pause"})}
  end

  def handle_event("read_aloud_stop", _params, socket) do
    {:noreply,
     socket
     |> assign(:read_aloud_active, false)
     |> assign(:read_aloud_playing, false)
     |> push_event("read_aloud", %{action: "stop"})}
  end

  # ── Pre-existing event handlers ──────────────────────────────────────────

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("toggle_view_mode", _params, socket) do
    new_mode = if socket.assigns.view_mode == :edit, do: :preview, else: :edit
    {:noreply, assign(socket, :view_mode, new_mode)}
  end

  def handle_event("toggle_panel", %{"side" => side, "item" => item}, socket)
      when side in ["left", "right"] do
    case Enum.find(@panels, &(Atom.to_string(&1) == item)) do
      nil ->
        {:noreply, socket}

      panel ->
        key = if side == "left", do: :left_panel, else: :right_panel
        current = socket.assigns[key]
        {:noreply, assign(socket, key, if(current == panel, do: nil, else: panel))}
    end
  end

  def handle_event("toggle_panel", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_fullscreen", _params, socket) do
    {:noreply, assign(socket, :fullscreen, !socket.assigns.fullscreen)}
  end

  def handle_event("toggle_split_view", _params, socket) do
    {:noreply, assign(socket, :split_view, !socket.assigns.split_view)}
  end

  def handle_event("rotate_cw", _params, socket) do
    rotation = rem(socket.assigns.rotation + 90, 360)
    {:noreply, assign(socket, :rotation, rotation) |> push_event("rotate", %{rotation: rotation})}
  end

  def handle_event("rotate_ccw", _params, socket) do
    rotation = rem(socket.assigns.rotation - 90, 360)
    rotation = if rotation < 0, do: rotation + 360, else: rotation
    {:noreply, assign(socket, :rotation, rotation) |> push_event("rotate", %{rotation: rotation})}
  end

  def handle_event("reset_rotation", _params, socket) do
    {:noreply, assign(socket, :rotation, 0) |> push_event("rotate", %{rotation: 0})}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  defp rail_items(items, active_panel) do
    Enum.map(items, &Map.put(&1, :active, &1.id == active_panel))
  end

  # Pushes the current query plus options to the viewer hook, or clears
  # the panel locally when the query is emptied.
  defp run_search(socket) do
    if socket.assigns.search_query == "" do
      socket
      |> assign(:search_results, [])
      |> assign(:search_total, 0)
      |> assign(:search_current, 0)
      |> assign(:searching, false)
    else
      socket
      |> assign(:searching, true)
      |> push_event("find", %{
        query: socket.assigns.search_query,
        match_case: socket.assigns.search_match_case,
        whole_word: socket.assigns.search_whole_word
      })
    end
  end

  # Moves the current result by `delta`, wrapping at both ends, and
  # scrolls the viewer to the newly selected match's page.
  defp step_search(socket, delta) do
    results = socket.assigns.search_results

    if results == [] do
      socket
    else
      index = rem(socket.assigns.search_current + delta + length(results), length(results))
      page = results |> Enum.at(index) |> Map.get(:page) |> max(1) |> min(socket.assigns.total_pages)

      socket
      |> assign(:search_current, index)
      |> assign(:page, page)
      |> push_event("navigate_page", %{page: page})
    end
  end

  defp page_for_key("PageUp", assigns), do: max(assigns.page - 1, 1)
  defp page_for_key("PageDown", assigns), do: min(assigns.page + 1, assigns.total_pages)
  defp page_for_key("Home", _assigns), do: 1
  defp page_for_key("End", assigns), do: assigns.total_pages

  # Matches the ZoomControl presets; keyboard zoom steps through them.
  @zoom_levels [50, 75, 100, 125, 150, 200]

  defp zoom_for_key(key, zoom) when key in ["=", "+"] do
    Enum.find(@zoom_levels, List.last(@zoom_levels), &(&1 > zoom))
  end

  defp zoom_for_key("-", zoom) do
    @zoom_levels |> Enum.reverse() |> Enum.find(hd(@zoom_levels), &(&1 < zoom))
  end

  # "0" (fit page) and "1" (actual size) both resolve to 100% until a
  # document is loaded and fit-page can be computed from real geometry.
  defp zoom_for_key(_key, _zoom), do: 100

  # Removes a document from the list and adjusts active_document_id.
  defp remove_doc(socket, id) do
    docs = socket.assigns.documents
    remaining = Enum.reject(docs, &(&1.id == id))

    new_active =
      cond do
        # If we removed the active doc, pick the nearest neighbour
        socket.assigns.active_document_id == id ->
          case remaining do
            [] -> nil
            list -> Enum.at(list, min(length(docs) - 2, 0)).id
          end

        # Active doc unchanged
        true ->
          socket.assigns.active_document_id
      end

    new_title =
      if doc = Enum.find(remaining, &(&1.id == new_active)) do
        doc.title
      else
        nil
      end

    socket
    |> assign(:documents, remaining)
    |> assign(:active_document_id, new_active)
    |> assign(:document_title, new_title)
  end

  defp coerce_id(id) when is_binary(id), do: id
  defp coerce_id(id) when is_integer(id), do: Integer.to_string(id)

  defp confirm_close_modal(assigns) do
    {doc_id, doc_title} = assigns.confirm_close_doc

    assigns = assign(assigns, :doc_id, doc_id) |> assign(:doc_title, doc_title)

    ~H"""
    <.modal title="Unsaved changes" on_close="cancel_close" open={true}>
      <p class="text-sm text-gray-600 dark:text-gray-400 mb-4">
        "{@doc_title}" has unsaved changes.
      </p>
      <div class="flex justify-end gap-2">
        <.button phx-click="save_and_close" variant="primary">Save</.button>
        <.button
          phx-click="confirm_close"
          variant="outline"
          class="text-red-600 border-red-200 hover:bg-red-50"
        >
          Don't Save
        </.button>
        <.button phx-click="cancel_close" variant="outline">Cancel</.button>
      </div>
    </.modal>
    """
  end

  # The ribbon renders the active tab's LiveComponent (plan3.md §8.1);
  # those land with the §9 feature tickets. Until then the strip holds
  # its 84 px (`chrome-ribbon` token) with a hint. The view toggle pill
  # is chrome, not a ribbon tool, so it lives here directly: it flips
  # the whole document between :edit and :preview on tabs whose tools
  # mutate the document.
  attr :active_tab, :string, required: true
  attr :view_mode, :atom, values: [:edit, :preview], required: true

  @view_toggle_tabs ~w(edit comment secure forms esign ocr)

  defp ribbon_strip(assigns) do
    assigns = assign(assigns, :view_toggle_tabs, @view_toggle_tabs)

    ~H"""
    <div
      class="chrome-ribbon flex items-center px-4 bg-chrome-white dark:bg-gray-800 border-b border-chrome-border dark:border-gray-600"
      role="toolbar"
      aria-label="Ribbon"
      aria-orientation="horizontal"
    >
      <div
        :if={@active_tab in @view_toggle_tabs}
        class="flex items-center gap-2 pr-3 mr-3 border-r border-chrome-border dark:border-gray-600"
      >
        <button
          type="button"
          phx-click="toggle_view_mode"
          aria-label={
            if @view_mode == :preview, do: "Switch to edit mode", else: "Switch to preview mode"
          }
          class={[
            "flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs font-medium transition-all cursor-pointer",
            if(@view_mode == :preview,
              do: "bg-gray-900 text-white dark:bg-gray-100 dark:text-gray-900",
              else:
                "bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-300 dark:hover:bg-gray-600"
            )
          ]}
        >
          <.icon name="hero-eye" class="size-3.5" />
          <span>{if @view_mode == :preview, do: "Edit", else: "Preview"}</span>
        </button>
      </div>

      <p class="text-sm text-gray-400 dark:text-gray-500 italic px-4">Select a tool</p>
    </div>
    """
  end

  attr :side, :string, values: ["left", "right"], required: true
  attr :panel, :atom, required: true
  attr :pages, :list, default: []
  attr :page, :integer, default: 1
  attr :bookmarks, :list, default: []
  attr :layers, :list, default: []
  attr :attachments, :list, default: []
  attr :search_query, :string, default: ""
  attr :search_results, :list, default: []
  attr :search_total, :integer, default: 0
  attr :search_current, :integer, default: 0
  attr :search_match_case, :boolean, default: false
  attr :search_whole_word, :boolean, default: false
  attr :searching, :boolean, default: false

  defp side_panel(assigns) do
    ~H"""
    <aside
      class={[
        "w-64 shrink-0 flex flex-col bg-chrome-white dark:bg-gray-800 border-chrome-border dark:border-gray-600",
        if(@side == "left", do: "border-r", else: "border-l")
      ]}
      aria-label={panel_title(@panel)}
    >
      <div class="flex items-center justify-between px-4 py-3 border-b border-chrome-border dark:border-gray-600">
        <h2 class="text-sm font-medium text-gray-700 dark:text-gray-200">{panel_title(@panel)}</h2>
        <button
          type="button"
          phx-click="toggle_panel"
          phx-value-side={@side}
          phx-value-item={@panel}
          aria-label={"Close #{panel_title(@panel)} panel"}
          class="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors cursor-pointer"
        >
          <.icon name="hero-x-mark" class="size-4 text-gray-500 dark:text-gray-400" />
        </button>
      </div>
      <%= cond do %>
        <% @panel == :thumbnails -> %>
          <.thumbnails_panel pages={@pages} current_page={@page} />
        <% @panel == :bookmarks -> %>
          <.bookmarks_panel bookmarks={@bookmarks} current_page={@page} />
        <% @panel == :layers -> %>
          <.layers_panel layers={@layers} />
        <% @panel == :attachments -> %>
          <.attachments_panel attachments={@attachments} />
        <% @panel == :search -> %>
          <.search_panel
            query={@search_query}
            results={@search_results}
            total_results={@search_total}
            current_result={@search_current}
            match_case={@search_match_case}
            whole_word={@search_whole_word}
            searching={@searching}
          />
        <% true -> %>
          <div class="flex-1 overflow-y-auto p-4">
            <p class="text-sm text-gray-400 dark:text-gray-500">Unknown panel</p>
          </div>
      <% end %>
    </aside>
    """
  end

  defp panel_title(:thumbnails), do: "Thumbnails"
  defp panel_title(:bookmarks), do: "Bookmarks"
  defp panel_title(:layers), do: "Layers"
  defp panel_title(:search), do: "Search"
  defp panel_title(:attachments), do: "Attachments"

  defp no_document_placeholder(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-3 text-center select-none">
      <.icon name="hero-document" class="size-12 text-gray-300 dark:text-gray-600" />
      <p class="text-sm text-gray-400 dark:text-gray-500">No document open</p>
    </div>
    """
  end
end
