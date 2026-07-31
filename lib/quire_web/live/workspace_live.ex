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

  alias Quire.Editing
  alias Quire.Ocr.Results, as: OcrResults

  import QuireWeb.Chrome.AttachmentsPanel, only: [attachments_panel: 1]
  import QuireWeb.Chrome.Backstage, only: [backstage: 1]
  import QuireWeb.Chrome.BookmarksPanel, only: [bookmarks_panel: 1]
  import QuireWeb.Chrome.DocumentTabs, only: [document_tabs: 1]
  import QuireWeb.Chrome.EmailCompose, only: [email_compose: 1]
  import QuireWeb.Chrome.EsignWizard, only: [esign_wizard: 1]
  import QuireWeb.Chrome.LayersPanel, only: [layers_panel: 1]
  import QuireWeb.Chrome.MenuBar, only: [menu_bar: 1]
  import QuireWeb.Chrome.Rail, only: [rail: 1]
  import QuireWeb.Chrome.SearchPanel, only: [search_panel: 1]
  import QuireWeb.Chrome.SignaturesPanel, only: [signatures_panel: 1]
  import QuireWeb.Chrome.ShortcutsModal, only: [shortcuts_modal: 1]
  import QuireWeb.Chrome.StatusBar, only: [status_bar: 1]
  import QuireWeb.Chrome.ThumbnailsPanel, only: [thumbnails_panel: 1]
  import QuireWeb.Chrome.TitleBar, only: [title_bar: 1]
  import QuireWeb.Chrome.RibbonGroup, only: [ribbon_group: 1]
  import QuireWeb.Chrome.RibbonButton, only: [ribbon_button: 1]
  import QuireWeb.Chrome.RibbonSplitButton, only: [ribbon_split_button: 1]
  import QuireWeb.Shared.Modal, only: [modal: 1]
  import Ecto.Query, only: [from: 2]

  # The shell markup lives in workspace_live/workspace.html.heex (T-033);
  # render/1 below only precomputes derived assigns and delegates to it.
  embed_templates "workspace_live/*"

  @left_rail_items [
    %{id: :thumbnails, icon: "hero-squares-2x2", label: "Thumbnails"},
    %{id: :bookmarks, icon: "hero-bookmark", label: "Bookmarks"},
    %{id: :layers, icon: "hero-rectangle-stack", label: "Layers"},
    %{id: :signatures, icon: "hero-pencil", label: "Signatures"},
    %{id: :initials, icon: "hero-pencil-square", label: "Initials"},
    %{id: :comments, icon: "hero-chat-bubble-left-right", label: "Comments"},
    %{id: :confidence, icon: "hero-chart-bar", label: "OCR Confidence"}
  ]

  @right_rail_items [
    %{id: :search, icon: "hero-magnifying-glass", label: "Search"},
    %{id: :attachments, icon: "hero-paper-clip", label: "Attachments"},
    %{id: :translate, icon: "hero-language", label: "Translate"}
  ]

  @panels [
    :thumbnails,
    :bookmarks,
    :layers,
    :search,
    :attachments,
    :signatures,
    :initials,
    :comments,
    :confidence,
    :translate
  ]

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
      |> assign(:has_form_fields, false)
      |> assign(:view_mode, :edit)
      |> assign(:left_panel, nil)
      |> assign(:right_panel, nil)
      |> assign(:page, 1)
      |> assign(:total_pages, doc_page_count)
      |> assign(:thumbnails, [])
      |> assign(:bookmarks, [])
      |> assign(:layers, [])
      |> assign(:attachments, [])
      |> assign(:signatures, [])
      |> assign(:initials, [])
      |> assign(:signing_date_format, "%Y-%m-%d")
      |> assign(:signer_name, nil)
      |> assign(:search_query, "")
      |> assign(:search_pages, [])
      |> assign(:search_total, 0)
      |> stream(:search_results, [], reset: true)
      |> assign(:search_current, 0)
      |> assign(:search_match_case, false)
      |> assign(:search_whole_word, false)
      |> assign(:searching, false)
      |> assign(:zoom, 100)
      |> assign(:scroll_mode, :vertical)
      |> assign(:spread_mode, :none)
      |> assign(:fit_mode, :fit_page)
      |> assign(:fullscreen, false)
      |> assign(:rotation, 0)
      |> assign(:split_view, false)
      |> assign(:snapshot_active, false)
      |> assign(:read_aloud_active, false)
      |> assign(:read_aloud_playing, false)
      |> assign(:mutations_pending, false)
      |> assign(:pending_server_op, nil)
      |> assign(:read_only?, false)
      |> assign(:progress, nil)
      |> assign(:show_shortcuts, false)
      |> assign(:backstage_open, false)
      |> assign(:backstage_view, nil)
      |> assign(:show_email_compose, false)
      |> assign(:show_esign_wizard, false)
      |> assign(:esign_wizard_step, :signers)
      |> assign(:esign_wizard_signers, [])
      |> assign(:esign_wizard_fields, [])
      |> assign(:esign_wizard_subject, "")
      |> assign(:esign_wizard_message, "")
      |> assign(:esign_wizard_expires_at, nil)
      |> assign(:esign_wizard_sending, false)
      |> assign(:esign_wizard_error, nil)
      |> assign(:builtin_stamps, builtin_stamps())
      |> assign(:selected_stamp_id, nil)
      |> assign(:stamp_mode_active, false)
      |> assign(:attachment_mode_active, false)
      |> assign(:callout_mode_active, false)
      |> assign(:stamps, [])
      |> assign(:ocr_running, false)
      |> assign(:ocr_progress, nil)
      |> assign(:show_ocr_options, false)
      |> assign(:show_ocr_confidence, false)
      |> assign(:ocr_confidence_result, nil)
      |> assign(:show_activate_modal, false)
      |> assign(:show_ocr_prompt, false)
      |> assign(:ocr_prompt_dismissed, false)
      |> assign(:measure_mode_active, false)
      |> assign(:active_measure_mode, nil)
      |> assign(:calibrating, false)
      |> assign(:calibration_scale, 1.0)
      |> assign(:calibration_unit, "mm")
      |> assign(:measure_modal_open, false)
      |> assign(:cal_known_length, "")
      |> assign(:cal_known_unit, "mm")
      |> assign(:cal_drawn_points, nil)
      |> assign(:cal_page_index, nil)
      |> assign(:whiteout_mode_active, false)
      |> assign(:whiteout_warning_visible, false)
      |> assign(:whiteout_warning_dismissed, false)
      |> assign(:image_ocr_uploading, false)
      |> assign(:image_ocr_error, nil)
      |> assign(:show_camera_capture, false)
      |> assign(:scan_job_id, nil)
      |> assign(:scan_progress, nil)
      |> assign(:scan_error, nil)
      |> assign(:convert_running, false)
      |> assign(:convert_format, nil)
      |> assign(:convert_error, nil)
      |> assign(:form_detect_running, false)
      |> assign(:form_detect_progress, nil)
      |> assign(:form_detect_operation_id, nil)
      |> assign(:form_detections, nil)
      |> assign(:clipboard_fallback, false)
      |> assign(:clipboard_fallback_msg, nil)
      |> assign(:translate_source, "detect")
      |> assign(:translate_target, "en")
      |> assign(:translate_mode, "overlay")
      |> assign(:translate_provider_label, provider_label())
      |> assign(:translate_results, [])
      |> assign(:show_merge_wizard, false)
      |> assign(:show_compress_wizard, false)
      |> assign(:compress_preset, "medium")
      |> assign(:compress_custom_quality, "60")
      |> assign(:compress_custom_max_width, "2048")
      |> assign(:compress_remove_a11y, false)
      |> assign(:compress_running, false)
      |> assign(:compress_error, nil)
      |> assign(:compress_preview, nil)
      |> assign(:show_split_wizard, false)
      |> assign(:split_mode, "every_n")
      |> assign(:split_n, "5")
      |> assign(:split_level, "1")
      |> assign(:split_ranges, "")
      |> assign(:split_size, "1mb")
      |> assign(:split_extract, "")
      |> assign(:split_running, false)
      |> assign(:split_error, nil)
      |> assign(:merge_files, [])
      |> assign(:merge_numbering, true)
      |> assign(:merge_bookmarks, "keep")
      |> assign(:merge_forms, "keep")
      |> assign(:merge_running, false)
      |> assign(:merge_error, nil)
      |> load_user_settings()
      |> load_saved_signatures()
      |> load_saved_initials()
      |> allow_upload(:image,
        accept: ~w(image/png image/jpeg image/webp),
        max_entries: 1,
        max_file_size: 50_000_000
      )
      |> allow_upload(:insert_pdf,
        accept: ~w(application/pdf),
        max_entries: 1,
        max_file_size: 100_000_000
      )
      |> allow_upload(:merge_files,
        accept: ~w(application/pdf),
        max_entries: 12,
        max_file_size: 50_000_000,
        auto_upload: true
      )

    Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{id}")

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

  def handle_event("show_activate_modal", _params, socket) do
    {:noreply, assign(socket, :show_activate_modal, true)}
  end

  def handle_event("close_activate", _params, socket) do
    {:noreply, assign(socket, :show_activate_modal, false)}
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

  # ── E-Sign wizard event handlers (T-147) ─────────────────────────────────

  @impl true
  def handle_event("open_esign_wizard", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_esign_wizard, true)
     |> assign(:esign_wizard_step, :signers)
     |> assign(:esign_wizard_signers, [])
     |> assign(:esign_wizard_fields, [])
     |> assign(:esign_wizard_subject, "")
     |> assign(:esign_wizard_message, "")
     |> assign(:esign_wizard_expires_at, nil)
     |> assign(:esign_wizard_sending, false)
     |> assign(:esign_wizard_error, nil)}
  end

  def handle_event("close_esign_wizard", _params, socket) do
    {:noreply, assign(socket, :show_esign_wizard, false)}
  end

  def handle_event("esign_wizard_next", _params, socket) do
    steps = [:signers, :fields, :compose, :expiry, :send]
    current = socket.assigns.esign_wizard_step
    idx = Enum.find_index(steps, &(&1 == current))

    if idx && idx < length(steps) - 1 do
      next = Enum.at(steps, idx + 1)

      socket =
        if next == :fields do
          push_event(socket, "enable_esign_placement", %{})
        else
          if current == :fields do
            push_event(socket, "disable_esign_placement", %{})
          else
            socket
          end
        end

      {:noreply, assign(socket, :esign_wizard_step, next)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("esign_wizard_prev", _params, socket) do
    steps = [:signers, :fields, :compose, :expiry, :send]
    current = socket.assigns.esign_wizard_step
    idx = Enum.find_index(steps, &(&1 == current))

    if idx && idx > 0 do
      prev = Enum.at(steps, idx - 1)

      socket =
        if current == :fields do
          push_event(socket, "disable_esign_placement", %{})
        else
          socket
        end

      {:noreply, assign(socket, :esign_wizard_step, prev)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("esign_wizard_add_signer", _params, socket) do
    signers = socket.assigns.esign_wizard_signers
    order = length(signers) + 1
    new_signer = %{name: "", email: "", role: "", order: order}
    {:noreply, assign(socket, :esign_wizard_signers, signers ++ [new_signer])}
  end

  def handle_event("esign_wizard_remove_signer", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    signers = List.delete_at(socket.assigns.esign_wizard_signers, index)
    signers = Enum.with_index(signers, 1) |> Enum.map(fn {s, i} -> %{s | order: i} end)
    {:noreply, assign(socket, :esign_wizard_signers, signers)}
  end

  def handle_event("esign_wizard_update_signer", params, socket) do
    # phx-change sends the input value under the input's name key,
    # plus phx-value-index and phx-value-field attrs
    index = String.to_integer(Map.get(params, "index", "0"))
    field = Map.get(params, "field", "name")
    value = Map.get(params, params["_target"] |> List.last() || "name", "")
    signers = socket.assigns.esign_wizard_signers

    updated =
      Enum.with_index(signers)
      |> Enum.map(fn
        {s, i} when i == index -> Map.put(s, String.to_existing_atom(field), value)
        {s, _} -> s
      end)

    {:noreply, assign(socket, :esign_wizard_signers, updated)}
  end

  def handle_event("esign_wizard_add_field", %{"signer_index" => idx}, socket) do
    signer_index = String.to_integer(idx)

    new_field = %{
      id: Ecto.UUID.generate(),
      signer_index: signer_index,
      kind: :signature,
      page_index: 0
    }

    socket =
      assign(socket, :esign_wizard_fields, socket.assigns.esign_wizard_fields ++ [new_field])

    {:noreply, push_event(socket, "enable_esign_placement", %{})}
  end

  def handle_event("esign_wizard_place_field", %{"page_index" => pi, "rect" => rect}, socket) do
    # Called by pdf_viewer_hook when user clicks on the viewer in placement mode
    fields = socket.assigns.esign_wizard_fields

    # Update the last added field with coordinates
    updated =
      case List.last(fields) do
        nil ->
          fields

        last ->
          List.replace_at(
            fields,
            length(fields) - 1,
            Map.merge(last, %{page_index: pi, rect: rect})
          )
      end

    {:noreply, assign(socket, :esign_wizard_fields, updated)}
  end

  def handle_event("esign_wizard_remove_field", %{"id" => field_id}, socket) do
    {:noreply,
     assign(
       socket,
       :esign_wizard_fields,
       Enum.reject(socket.assigns.esign_wizard_fields, &(&1.id == field_id))
     )}
  end

  def handle_event("esign_wizard_update_field", params, socket) do
    field_id = Map.get(params, "id", "")
    field_key = Map.get(params, "field", "kind")
    value_raw = Map.get(params, "kind", "signature")

    kind =
      case field_key do
        "kind" -> String.to_existing_atom(value_raw)
        _ -> value_raw
      end

    fields =
      Enum.map(socket.assigns.esign_wizard_fields, fn
        f when f.id == field_id -> Map.put(f, String.to_existing_atom(field_key), kind)
        f -> f
      end)

    {:noreply, assign(socket, :esign_wizard_fields, fields)}
  end

  def handle_event("esign_wizard_update_compose", params, socket) do
    field = Map.get(params, "field", "subject")
    value = Map.get(params, field, "")
    {:noreply, assign(socket, String.to_existing_atom("esign_wizard_#{field}"), value)}
  end

  def handle_event("esign_wizard_update_expiry", params, socket) do
    value = Map.get(params, "expires_at", "")

    expires_at =
      case value do
        "" -> nil
        str -> NaiveDateTime.from_iso8601!(str) |> DateTime.from_naive!("Etc/UTC")
      end

    {:noreply, assign(socket, :esign_wizard_expires_at, expires_at)}
  end

  def handle_event("esign_wizard_send", _params, socket) do
    %{assigns: assigns} = socket
    signers = assigns.esign_wizard_signers
    _fields = assigns.esign_wizard_fields
    subject = assigns.esign_wizard_subject
    message = assigns.esign_wizard_message
    expires_at = assigns.esign_wizard_expires_at

    socket = assign(socket, :esign_wizard_sending, true)
    socket = assign(socket, :esign_wizard_error, nil)

    if length(signers) == 0 do
      {:noreply,
       socket
       |> assign(:esign_wizard_error, "At least one signer is required")
       |> assign(:esign_wizard_sending, false)}
    else
      doc_id = assigns.active_document_id
      owner = assigns.current_scope

      # Create envelope via Esign context
      case Quire.Esign.create_envelope(%{
             document_id: doc_id,
             owner_id: owner.user.id,
             subject: subject,
             message: message,
             expires_at: expires_at
           }) do
        {:ok, envelope} ->
          # Add signers
          results =
            Enum.map(signers, fn s ->
              Quire.Esign.add_signer(envelope, %{
                name: s.name,
                email: s.email,
                role: s.role,
                order: s.order
              })
            end)

          errors = Enum.filter(results, &match?({:error, _}, &1))

          if length(errors) > 0 do
            {:noreply,
             socket
             |> assign(:esign_wizard_error, "Failed to add signers")
             |> assign(:esign_wizard_sending, false)}
          else
            # Send envelope
            case Quire.Esign.send_envelope(envelope) do
              {:ok, _env} ->
                {:noreply,
                 socket
                 |> assign(:show_esign_wizard, false)
                 |> assign(:esign_wizard_sending, false)}

              {:error, reason} ->
                {:noreply,
                 socket
                 |> assign(:esign_wizard_error, "Failed to send: #{inspect(reason)}")
                 |> assign(:esign_wizard_sending, false)}
            end
          end

        {:error, changeset} ->
          {:noreply,
           socket
           |> assign(
             :esign_wizard_error,
             "Failed to create envelope: #{inspect(changeset.errors)}"
           )
           |> assign(:esign_wizard_sending, false)}
      end
    end
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

  # ── Scripting toggle handler (pdf-fkm) ──────────────────────────────────

  @impl true
  def handle_event("toggle_scripting", %{"enabled" => enabled}, socket) do
    enabled? = enabled in [true, "true"]

    Quire.Accounts.update_user_settings(socket.assigns.current_scope.user.id, %{
      scripting_enabled: enabled?
    })

    {:noreply,
     socket
     |> assign(:scripting_enabled, enabled?)
     |> push_event("set_scripting", %{enabled: enabled?})}
  end

  # ── Annotation event handlers (T-107) ──────────────────────────────────

  # Receives a committed annotation from the annot_edit_hook.
  # Handles all annotation types: text-markup, shapes, stamps,
  # file attachments, and free-text callouts.
  def handle_event("annot_committed", %{"type" => type, "data" => data}, socket) do
    document_id = socket.assigns.active_document_id

    socket =
      case type do
        # File attachment — store file bytes via Quire.Storage
        "file_attachment" ->
          handle_file_attachment_commit(socket, document_id, data)

        # Stamp annotation
        "stamp" ->
          handle_stamp_commit(socket, document_id, data)

        # Free-text callout
        "free_text_callout" ->
          handle_callout_commit(socket, document_id, data)

        # Whiteout — record annotation and show warning
        "whiteout" ->
          socket = handle_annotation_commit(socket, document_id, type, data)

          show_warning = !socket.assigns.whiteout_warning_dismissed

          assign(socket, :whiteout_warning_visible, show_warning)

        # All other types (shapes, native pdf.js annotations)
        _ ->
          handle_annotation_commit(socket, document_id, type, data)
      end

    {:noreply, socket}
  end

  def handle_event("annot_deleted", %{"id" => _id}, socket) do
    # T-088: annotation deletion handled via DocMutateHook
    {:noreply, socket}
  end

  def handle_event("annot_mode_changed", %{"mode" => _mode}, socket) do
    {:noreply, socket}
  end

  # Update ribbon active state when user switches annotation mode via JS
  def handle_event("toggle_annot_mode", %{"mode" => mode}, socket) do
    socket =
      socket
      |> assign(:stamp_mode_active, mode == "stamp")
      |> assign(:attachment_mode_active, mode == "file_attachment")
      |> assign(:callout_mode_active, mode == "free_text_callout")
      |> assign(
        :measure_mode_active,
        mode in ~w(measure_distance measure_perimeter measure_area)
      )
      |> assign(
        :active_measure_mode,
        if(mode in ~w(measure_distance measure_perimeter measure_area), do: mode, else: nil)
      )
      |> assign(:whiteout_mode_active, mode == "whiteout")
      |> push_event("toggle_annot_mode", %{mode: mode})

    {:noreply, socket}
  end

  @doc """
  Handles a click on text in edit mode (T-091, pdf-8vsn).

  Identifies the text run at the click position via
  `RunIdentifier.identify_runs/2`, checks font availability, and pushes
  an `open_text_editor` event to the client.
  """
  def handle_event("edit_text_click", %{"page_index" => pi, "x" => x, "y" => y}, socket) do
    doc_id = socket.assigns.active_document_id

    socket =
      with {:ok, doc} <- Quire.Documents.get_document(doc_id, socket.assigns.current_scope),
           {:ok, rev} <- Quire.Documents.current_revision(doc),
           %Quire.Storage.Ref{} = ref <- Quire.Documents.Revision.storage_ref(rev),
           {:ok, runs} <- Quire.Editor.RunIdentifier.identify_runs(ref, pi) do
        run = find_run_at_click(runs, x, y)

        if run do
          case Quire.Editor.RunIdentifier.check_font_available(run) do
            :ok ->
              push_event(socket, "open_text_editor", %{
                text: run.text,
                bbox: run.bbox,
                font_name: run.font_name,
                font_size: run.font_size,
                page_index: pi
              })

            {:error, :font_unavailable, msg} ->
              put_flash(socket, :warning, msg)
          end
        else
          put_flash(socket, :info, "No editable text found at that position.")
        end
      else
        _ -> put_flash(socket, :error, "Could not identify text at click position.")
      end

    {:noreply, socket}
  end

  def handle_event("open_attachments_panel", _params, socket) do
    {:noreply, assign(socket, :right_panel, :attachments)}
  end

  def handle_event("toggle_custom_stamps", _params, socket) do
    {:noreply, socket}
  end

  # Toggle the OCR options panel.
  def handle_event("toggle_ocr_options", _params, socket) do
    {:noreply, assign(socket, :show_ocr_options, !socket.assigns.show_ocr_options)}
  end

  # Enqueue OcrWorker for the current document revision.
  def handle_event("run_ocr", %{"options" => options}, socket) do
    enqueue_ocr(socket, options)
  end

  # Legacy run_ocr without options (direct button click, not through panel).
  def handle_event("run_ocr", _params, socket) do
    default_opts = %{
      "languages" => "eng",
      "mode" => "skip",
      "deskew" => true,
      "rotate" => true,
      "clean" => true,
      "optimise" => 1
    }

    enqueue_ocr(socket, default_opts)
  end

  defp enqueue_ocr(socket, options, page_range \\ nil) do
    doc_id = socket.assigns.active_document_id

    with {:ok, doc} <- Quire.Documents.get_document(doc_id, socket.assigns.current_scope),
         {:ok, rev} <- Quire.Documents.current_revision(doc) do
      args =
        %{
          "doc_id" => doc_id,
          "revision_id" => rev.id,
          "options" => options
        }

      # Pass page_range when re-running selected pages
      args =
        if page_range do
          Map.put(args, "page_range", page_range)
        else
          args
        end

      args
      |> Quire.Workers.OcrWorker.new([])
      |> Oban.insert!()

      {:noreply,
       socket
       |> assign(:ocr_running, true)
       |> assign(:ocr_progress, %{pct: 0})
       |> assign(:show_ocr_options, false)
       |> put_flash(:info, "OCR started on #{doc.title}")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start OCR: #{reason}")}
    end
  end

  # Attachments panel (T-107) — download/extract an embedded file attachment.
  # File bytes are retrieved from Quire.Storage via the attachment_ref.
  def handle_event("preview_attachment", %{"name" => _name}, socket) do
    {:noreply, socket}
  end

  def handle_event("download_attachment", %{"ref" => _ref}, socket) do
    # T-107: serve bytes through a download route or direct push
    {:noreply, socket}
  end

  # ── Custom stamp event handlers (T-107) ────────────────────────────────

  def handle_event("save_custom_stamp", params, socket) do
    user_id = socket.assigns.current_scope.user.id

    params =
      if is_binary(params["data"]),
        do: Map.put(params, "data", Jason.decode!(params["data"])),
        else: params

    case Quire.Accounts.save_stamp(user_id, params) do
      {:ok, _stamp} ->
        {:noreply, put_flash(socket, :info, "Stamp saved")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save stamp")}
    end
  end

  def handle_event("delete_stamp", %{"id" => stamp_id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    Quire.Accounts.delete_saved_stamp(user_id, stamp_id)
    {:noreply, socket}
  end

  def handle_event("select_builtin_stamp", %{"stamp_id" => stamp_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_stamp_id, stamp_id)
     |> push_event("select_stamp", %{stampId: stamp_id})}
  end

  def handle_event("select_custom_stamp", %{"stamp_id" => stamp_id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    stamps = Quire.Accounts.list_saved_stamps(user_id)
    stamp = Enum.find(stamps, &(&1["id"] == stamp_id))

    if stamp do
      {:noreply,
       socket
       |> assign(:selected_stamp_id, stamp_id)
       |> push_event("select_stamp", %{stampId: stamp["type"], customData: stamp["data"]})}
    else
      {:noreply, socket}
    end
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
    socket = assign(socket, :total_pages, page_count)

    if socket.assigns.ocr_prompt_dismissed do
      {:noreply, socket}
    else
      {:noreply, check_text_layer(socket)}
    end
  end

  def handle_event("document_ready", %{"total_pages" => total_pages} = params, socket) do
    page = Map.get(params, "current_page", 1)
    {:noreply, assign(socket, :total_pages, total_pages) |> assign(:page, page)}
  end

  def handle_event("zoom_changed", %{"zoom" => zoom}, socket) do
    {:noreply, assign(socket, :zoom, zoom)}
  end

  # Flush pending client edits (pdf-7ov): the hook returned saved bytes.
  # Create an intermediate revision, clear the pending op, and either
  # retry the pending server op or just acknowledge.
  def handle_event("document_saved", %{"bytes" => base64}, socket) do
    bytes = Base.decode64!(base64)
    document_id = socket.assigns.document_id
    user_id = socket.assigns.current_scope.user.id

    case Editing.open_session(document_id, user_id) do
      {:ok, session_pid} ->
        case Editing.flush(session_pid, bytes) do
          {:ok, %{revision_id: rev_id}} ->
            socket = assign(socket, :pending_server_op, nil)
            {:noreply, put_flash(socket, :info, "Edits auto-saved (rev #{rev_id}).")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to save edits: #{reason}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Session error: #{reason}")}
    end
  end

  def handle_event("save_error", %{"reason" => reason}, socket) do
    {:noreply,
     socket
     |> assign(:pending_server_op, nil)
     |> put_flash(:error, "Could not save pending edits: #{reason}")}
  end

  # DocMutateHook (T-088): a client-side mutation was applied optimistically
  # and the result bytes are ready. Store the inverse for potential revert.
  def handle_event("document_mutated", %{"kind" => kind, "data" => data}, socket) do
    op = %{kind: kind, data: data}
    document_id = socket.assigns.document_id
    user_id = socket.assigns.current_scope.user.id

    with {:ok, session_pid} <- Editing.open_session(document_id, user_id),
         {:ok, _} <- Editing.apply(session_pid, op) do
      {:noreply,
       socket
       |> assign(:mutations_pending, true)
       |> put_flash(:info, "Applied: #{kind}")}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> push_event("reject_mutation", %{})
         |> put_flash(:error, "Mutation rejected: #{reason}")}
    end
  end

  def handle_event("mutation_error", %{"reason" => reason}, socket) do
    {:noreply, put_flash(socket, :error, "Mutation error: #{reason}")}
  end

  def handle_event("set_scroll_mode", %{"scroll_mode" => current}, socket)
      when current in ~w(vertical horizontal wrapped) do
    mode = next_scroll_mode(String.to_existing_atom(current))

    {:noreply,
     socket
     |> assign(:scroll_mode, mode)
     |> push_event("set_scroll_mode", %{mode: mode})}
  end

  defp next_scroll_mode(:vertical), do: :horizontal
  defp next_scroll_mode(:horizontal), do: :wrapped
  defp next_scroll_mode(:wrapped), do: :vertical

  def handle_event("set_spread_mode", %{"spread_mode" => current}, socket)
      when current in ~w(none single odd even) do
    mode = next_spread_mode(String.to_existing_atom(current))

    {:noreply,
     socket
     |> assign(:spread_mode, mode)
     |> push_event("set_spread_mode", %{mode: mode})}
  end

  defp next_spread_mode(:none), do: :single
  defp next_spread_mode(:single), do: :odd
  defp next_spread_mode(:odd), do: :even
  defp next_spread_mode(:even), do: :none

  def handle_event("set_fit_mode", %{"fit_mode" => current}, socket)
      when current in ~w(fit_page fit_width actual_size) do
    mode = next_fit_mode(String.to_existing_atom(current))

    {:noreply,
     socket
     |> assign(:fit_mode, mode)
     |> push_event("set_fit_mode", %{mode: mode})}
  end

  defp next_fit_mode(:fit_page), do: :fit_width
  defp next_fit_mode(:fit_width), do: :actual_size
  defp next_fit_mode(:actual_size), do: :fit_page

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
  # pages, each %{"page" => n, "text" => snippet}. Rendered through a
  # LiveView stream (§14.2 "phx-update=stream for all long lists") so only
  # changed rows cross the wire; search_pages (small integer list) keeps
  # next/prev navigation indexable.
  def handle_event("search_results", %{"results" => results, "total" => total}, socket) do
    results =
      results
      |> Enum.with_index()
      |> Enum.map(fn {r, i} ->
        %{id: "sr-#{i}", page: r["page"], text: r["text"], index: i}
      end)

    {:noreply,
     socket
     |> stream(:search_results, results, reset: true)
     |> assign(:search_pages, Enum.map(results, & &1.page))
     |> assign(:search_total, total)
     |> assign(:search_current, 0)
     |> assign(:searching, false)}
  end

  def handle_event("search_navigate", %{"page" => page}, socket) do
    with {page, _} <- Integer.parse(to_string(page)) do
      page = page |> max(1) |> min(socket.assigns.total_pages)

      index =
        case Enum.find_index(socket.assigns.search_pages, &(&1 == page)) do
          nil -> 0
          i -> i
        end

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

  # ── Measurement / Calibration event handlers (T-108) ────────────────────

  def handle_event("calibrate_scale", _params, socket) do
    {:noreply,
     socket
     |> assign(:measure_modal_open, true)
     |> assign(:cal_known_length, "")
     |> assign(:cal_known_unit, socket.assigns.calibration_unit)
     |> assign(:cal_drawn_points, nil)
     |> assign(:cal_page_index, nil)
     |> push_event("cancel_calibration_draw", %{})}
  end

  def handle_event("close_calibration_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:measure_modal_open, false)
     |> push_event("cancel_calibration_draw", %{})}
  end

  def handle_event("update_cal_length", %{"_target" => _target} = params, socket) do
    value = Map.get(params, "value", "")
    {:noreply, assign(socket, :cal_known_length, value)}
  end

  def handle_event("update_cal_unit", %{"unit" => unit}, socket) do
    {:noreply, assign(socket, :cal_known_unit, unit)}
  end

  def handle_event("begin_calibration_draw", _params, socket) do
    {:noreply,
     socket
     |> assign(:calibrating, true)
     |> push_event("begin_calibration_draw", %{})}
  end

  def handle_event("calibration_line_drawn", %{"pdfLength" => pdf_len, "pageIndex" => pi}, socket) do
    {:noreply,
     socket
     |> assign(:cal_drawn_points, pdf_len)
     |> assign(:cal_page_index, pi)}
  end

  def handle_event("apply_calibration", params, socket) do
    known_len_str = Map.get(params, "known_length", socket.assigns.cal_known_length)
    known_unit = Map.get(params, "known_unit", socket.assigns.cal_known_unit)
    cal_drawn = socket.assigns.cal_drawn_points

    {known_len, _} = Float.parse(to_string(known_len_str))

    socket =
      if cal_drawn && known_len > 0 do
        # Scale factor = real-world length (in the given unit) / drawn length in PDF points
        # Measurement display: scaled_value = value_in_points * cal_factor
        factor = known_len / cal_drawn

        socket
        |> assign(:calibration_scale, factor)
        |> assign(:calibration_unit, known_unit)
        |> assign(:measure_modal_open, false)
        |> assign(:calibrating, false)
        |> push_event("set_calibration", %{factor: factor, unit: known_unit})
        |> push_event("cancel_calibration_draw", %{})
        |> put_flash(:info, "Scale calibrated: 1 pt = #{Float.round(factor, 6)} #{known_unit}")
      else
        socket
        |> put_flash(:error, "Draw a reference line and enter a known length")
      end

    {:noreply, socket}
  end

  def handle_event("set_measure_unit", %{"unit" => unit}, socket) do
    {:noreply,
     socket
     |> assign(:calibration_unit, unit)
     |> push_event("set_measure_unit", %{unit: unit})}
  end

  def handle_event("toggle_measure_mode", %{"mode" => mode}, socket) do
    {:noreply,
     socket
     |> assign(:measure_mode_active, socket.assigns.measure_mode_active != true)
     |> assign(
       :active_measure_mode,
       if(socket.assigns.measure_mode_active, do: nil, else: mode)
     )
     |> push_event("toggle_annot_mode", %{mode: mode})}
  end

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
    socket =
      if tab == "forms" do
        assign(socket, :has_form_fields, check_form_fields(socket))
      else
        socket
      end

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

  # ── Whiteout event handlers (T-109) ──────────────────────────────────────

  def handle_event("whiteout_committed", %{"data" => data}, socket) do
    document_id = socket.assigns.active_document_id
    user_id = socket.assigns.current_scope.user.id

    annot = %{
      revision_id: document_id,
      page_index: data["pageIndex"] || 0,
      kind: "whiteout",
      rect: data["rectPdf"] || data["rect"],
      path_data: data["pathData"],
      color: %{"r" => 255, "g" => 255, "b" => 255},
      opacity: 100,
      border_width: 0,
      author: socket.assigns.current_scope.user.name || user_id
    }

    socket = record_annotation(socket, document_id, user_id, annot)

    # Show warning unless permanently dismissed
    show_warning = !socket.assigns.whiteout_warning_dismissed

    {:noreply, assign(socket, :whiteout_warning_visible, show_warning)}
  end

  def handle_event("dismiss_whiteout_warning", _params, socket) do
    {:noreply, assign(socket, :whiteout_warning_visible, false)}
  end

  # Dismisses the OCR prompt for the current session.
  def handle_event("dismiss_ocr_prompt", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_ocr_prompt, false)
     |> assign(:ocr_prompt_dismissed, true)}
  end

  # ── Convert-to-Office handler (T-074 / pdf-wyh.1) ─────────────────────

  # Enqueues PdfToOfficeWorker for the selected format.
  def handle_event("convert_to_office", %{"format" => format}, socket) do
    doc_id = socket.assigns.active_document_id

    with {:ok, doc} <- Quire.Documents.get_document(doc_id, socket.assigns.current_scope),
         {:ok, rev} <- Quire.Documents.current_revision(doc) do
      %{
        "doc_id" => doc_id,
        "revision_id" => rev.id,
        "format" => format
      }
      |> Quire.Workers.PdfToOfficeWorker.new([])
      |> Oban.insert!()

      format_label = String.upcase(format)

      {:noreply,
       socket
       |> assign(:convert_running, true)
       |> assign(:convert_format, format)
       |> assign(:convert_error, nil)
       |> put_flash(:info, "#{format_label} conversion started for #{doc.title}")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start conversion: #{reason}")}
    end
  end

  @doc """
  Generates a self-contained HTML export (T-078) in a background task.

  `mode` is `"overlay"` (page WebP images + positioned selectable text) or
  `"text_only"` (semantic reflow, no images). The result is delivered as a
  browser download via the `{:download, ...}` handle_info.
  """
  def handle_event("convert_to_html", %{"mode" => mode}, socket) do
    doc_id = socket.assigns.active_document_id
    scope = socket.assigns.current_scope

    with {:ok, doc} <- Quire.Documents.get_document(doc_id, scope),
         {:ok, rev} <- Quire.Documents.current_revision(doc),
         %Quire.Storage.Ref{} = ref <- Quire.Documents.Revision.storage_ref(rev) do
      title = doc.title
      mode_atom = if mode == "text_only", do: :text_only, else: :overlay
      filename = "#{slugify(title)}.html"
      pid = self()

      Task.start(fn ->
        result =
          Quire.Office.Writer.PdfHtml.write(ref, :html,
            mode: mode_atom,
            title: title
          )

        case result do
          {:ok, html} ->
            send(pid, {:html_export_done, filename, html})

          {:error, reason} ->
            send(pid, {:convert_html_error, inspect(reason)})
        end
      end)

      {:noreply,
       socket
       |> assign(:convert_running, true)
       |> assign(:convert_format, "html")
       |> assign(:convert_error, nil)
       |> put_flash(:info, "HTML export started for #{title}")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "No PDF found for this document")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start export: #{reason}")}
    end
  end

  # T-079 Clipboard to PDF: receives base64 PDF bytes built client-side from
  # clipboard text/image (via `@cantoo/pdf-lib`), ingests them as a new
  # document (revision 1), and navigates to it in the workspace.
  def handle_event("clipboard_pdf_ready", params, socket) do
    scope = socket.assigns.current_scope
    filename = Map.get(params, "filename", "")

    case params do
      %{"bytes" => b64} ->
        case Base.decode64(b64) do
          {:ok, bytes} ->
            title =
              if is_binary(filename) and filename != "", do: filename, else: "Clipboard.pdf"

            case Quire.Documents.ingest(bytes, scope, title: title) do
              {:ok, %{document: doc}} ->
                {:noreply,
                 socket
                 |> assign(:clipboard_fallback, false)
                 |> assign(:clipboard_fallback_msg, nil)
                 |> put_flash(:info, "Clipboard PDF created — #{title}")
                 |> push_navigate(to: ~p"/workspace/#{doc.id}")}

              {:error, :invalid_pdf} ->
                {:noreply,
                 socket
                 |> assign(:clipboard_fallback, true)
                 |> assign(
                   :clipboard_fallback_msg,
                   "The clipboard content couldn't be turned into a valid PDF. Paste text or an image instead."
                 )}

              {:error, :password_required} ->
                {:noreply,
                 socket
                 |> assign(:clipboard_fallback, true)
                 |> assign(
                   :clipboard_fallback_msg,
                   "The clipboard PDF is password-protected and can't be opened."
                 )}

              {:error, reason} ->
                {:noreply,
                 socket
                 |> assign(:clipboard_fallback, true)
                 |> assign(
                   :clipboard_fallback_msg,
                   "Couldn't create the PDF from clipboard content (#{inspect(reason)}). Paste text or an image instead."
                 )}
            end

          :error ->
            {:noreply,
             socket
             |> assign(:clipboard_fallback, true)
             |> assign(
               :clipboard_fallback_msg,
               "The clipboard content couldn't be decoded. Try copying the text or image again."
             )}
        end

      _ ->
        {:noreply,
         socket
         |> assign(:clipboard_fallback, true)
         |> assign(
           :clipboard_fallback_msg,
           "The clipboard content couldn't be decoded. Try copying the text or image again."
         )}
    end
  end

  # T-079: clipboard read failed (permission denied, empty, or unsupported
  # format). Show the paste-target fallback with a plain-language message.
  def handle_event("clipboard_pdf_error", %{"code" => code}, socket) do
    {fallback, msg} =
      case code do
        "permission" ->
          {true,
           "Clipboard access was denied by the browser. Paste your text or image into the box below instead."}

        "empty" ->
          {true, "The clipboard is empty. Copy some text or an image first, then try again."}

        "unsupported" ->
          {true,
           "The clipboard contains a format that can't become a PDF — only text and PNG/JPEG images are supported."}

        _ ->
          {true,
           "Couldn't read the clipboard. Paste your text or image into the box below instead."}
      end

    {:noreply,
     socket |> assign(:clipboard_fallback, fallback) |> assign(:clipboard_fallback_msg, msg)}
  end

  # T-079: dismiss the paste-target fallback panel.
  def handle_event("clipboard_pdf_cancel", _params, socket) do
    {:noreply,
     socket |> assign(:clipboard_fallback, false) |> assign(:clipboard_fallback_msg, nil)}
  end

  # Delivers a finished HTML export as a browser download and clears the
  # convert-progress state.
  def handle_info({:html_export_done, filename, html}, socket) do
    {:noreply,
     socket
     |> assign(:convert_running, false)
     |> assign(:convert_format, nil)
     |> assign(:convert_error, nil)
     |> push_event("download", %{
       content: Base.encode64(html),
       filename: filename,
       content_type: "text/html; charset=utf-8"
     })
     |> put_flash(:info, "HTML export ready — #{filename} downloaded")}
  end

  # Marks a finished HTML export as complete (download already delivered).
  def handle_info({:convert_html_error, reason}, socket) do
    {:noreply,
     socket
     |> assign(:convert_running, false)
     |> assign(:convert_format, nil)
     |> assign(:convert_error, "HTML export failed: #{reason}")
     |> put_flash(:error, "HTML export failed")}
  end

  # Checks whether the document has any extractable text and assigns
  # `show_ocr_prompt` if all pages lack a text layer.
  defp check_text_layer(socket) do
    doc_id = socket.assigns.active_document_id
    scope = socket.assigns.current_scope

    with {:ok, doc} <- Quire.Documents.get_document(doc_id, scope),
         {:ok, rev} <- Quire.Documents.current_revision(doc) do
      has_any_text =
        Quire.Repo.all(
          from(p in Quire.Documents.Page,
            where: p.revision_id == ^rev.id and p.has_text == true,
            select: p.id,
            limit: 1
          )
        ) != []

      if has_any_text do
        assign(socket, :show_ocr_prompt, false)
      else
        assign(socket, :show_ocr_prompt, true)
      end
    else
      _ -> assign(socket, :show_ocr_prompt, false)
    end
  end

  def handle_event("dismiss_whiteout_permanently", _params, socket) do
    user_id = socket.assigns.current_scope.user.id

    Quire.Accounts.update_user_settings(user_id, %{whiteout_warning_dismissed: true})

    {:noreply,
     socket
     |> assign(:whiteout_warning_visible, false)
     |> assign(:whiteout_warning_dismissed, true)}
  end

  def handle_event("switch_to_redact", _params, socket) do
    {:noreply,
     socket
     |> assign(:whiteout_warning_visible, false)
     |> push_event("toggle_annot_mode", %{mode: "redact"})}
  end

  # ── Signature capture event handlers (T-114) ────────────────────────────

  def handle_event("save_signature", params, socket) do
    user_id = socket.assigns.current_scope.user.id

    params =
      if is_binary(params["data"]),
        do: Map.put(params, "data", Jason.decode!(params["data"])),
        else: params

    case Quire.Accounts.save_signature(user_id, params) do
      {:ok, _sig} ->
        {:noreply, load_saved_signatures(socket) |> put_flash(:info, "Signature saved")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save signature")}
    end
  end

  def handle_event("delete_signature", %{"id" => sig_id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    Quire.Accounts.delete_saved_signature(user_id, sig_id)
    {:noreply, load_saved_signatures(socket)}
  end

  def handle_event("signature_label_updated", %{"id" => sig_id, "label" => label}, socket) do
    user_id = socket.assigns.current_scope.user.id
    Quire.Accounts.update_signature_label(user_id, sig_id, label)
    {:noreply, load_saved_signatures(socket)}
  end

  def handle_event("signature_use", %{"id" => sig_id}, socket) do
    # T-115: Place the selected signature on the page — dispatch the saved
    # signature data to the client so it can enter placement mode.
    user_id = socket.assigns.current_scope.user.id

    case Enum.find(Quire.Accounts.list_saved_signatures(user_id), &(&1["id"] == sig_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Signature not found")}

      sig ->
        {:noreply, push_event(socket, "enable_signature_placement", %{signature: sig})}
    end
  end

  # ── Initials capture handlers (T-116) ───────────────────────────────────

  def handle_event("save_initials", params, socket) do
    user_id = socket.assigns.current_scope.user.id

    params =
      if is_binary(params["data"]),
        do: Map.put(params, "data", Jason.decode!(params["data"])),
        else: params

    case Quire.Accounts.save_initials(user_id, params) do
      {:ok, _initials} ->
        {:noreply, load_saved_initials(socket) |> put_flash(:info, "Initials saved")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save initials")}
    end
  end

  def handle_event("delete_initials", %{"id" => initials_id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    Quire.Accounts.delete_saved_initials(user_id, initials_id)
    {:noreply, load_saved_initials(socket)}
  end

  def handle_event("initials_label_updated", %{"id" => initials_id, "label" => label}, socket) do
    user_id = socket.assigns.current_scope.user.id
    Quire.Accounts.update_initials_label(user_id, initials_id, label)
    {:noreply, load_saved_initials(socket)}
  end

  def handle_event("initials_use", %{"id" => initials_id}, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Enum.find(Quire.Accounts.list_saved_initials(user_id), &(&1["id"] == initials_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Initials not found")}

      initials ->
        {:noreply,
         push_event(socket, "enable_signature_placement", %{signature: initials, kind: "initials"})}
    end
  end

  # ── Text-stamp handlers (T-116): signer name + signing date ──────────────

  def handle_event("name_stamp_use", _params, socket) do
    name = signer_name(socket)
    {:noreply, push_event(socket, "enable_name_stamp_placement", %{text: name})}
  end

  def handle_event("date_stamp_use", _params, socket) do
    format = socket.assigns.signing_date_format || "%Y-%m-%d"

    text =
      try do
        Calendar.strftime(DateTime.utc_now(), format)
      rescue
        _ -> Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")
      end

    {:noreply, push_event(socket, "enable_date_stamp_placement", %{text: text})}
  end

  defp signer_name(socket) do
    case socket.assigns do
      %{signer_name: name} when is_binary(name) and name != "" -> name
      _ -> socket.assigns.current_scope.user.email
    end
  end

  # Handles a committed signature placement (T-115): the client rasterised the
  # signature to PNG at the chosen box size and reports the rect in PDF points.
  # The server embeds the signature as a flattened XObject via the
  # `signature.place` op, journals it, flushes a new revision, and tells the
  # client to reload the document.
  def handle_event("signature_placed", params, socket) do
    doc_id = socket.assigns.active_document_id
    user_id = socket.assigns.current_scope.user.id

    with {:ok, page_index} <- fetch_int(params, "page_index"),
         {:ok, rect} <- fetch_rect(params["rect"]),
         {:ok, png} <- fetch_png(params["png"]),
         {:ok, doc} <- Quire.Documents.get_document(doc_id, socket.assigns.current_scope),
         {:ok, rev} <- Quire.Documents.current_revision(doc),
         %Quire.Storage.Ref{} = ref <- Quire.Documents.Revision.storage_ref(rev),
         {:ok, bytes} <- Quire.Storage.get(ref),
         {:ok, embedded} <-
           Quire.Editing.Ops.SignaturePlace.apply(
             %{pdf_bytes: bytes, page_index: page_index, rect: rect, png: png},
             %{}
           ),
         {:ok, session_pid} <- Editing.open_session(doc_id, user_id),
         {:ok, _} <-
           Editing.apply(session_pid, %{
             kind: "signature.place",
             data: %{
               page_index: page_index,
               rect: rect,
               kind: Map.get(params, "kind", "signature")
             }
           }),
         {:ok, %{revision_id: rev_id}} <-
           Editing.flush(session_pid, embedded, "Signature placed") do
      {:noreply,
       socket
       |> assign(:mutations_pending, true)
       |> push_event("open_document", %{url: socket.assigns.document_url, password: nil})
       |> put_flash(:info, "Signature placed (rev #{rev_id}).")}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> push_event("signature_placement_failed", %{reason: inspect(reason)})
         |> put_flash(:error, "Failed to place signature: #{inspect(reason)}")}

      _ ->
        {:noreply,
         push_event(socket, "signature_placement_failed", %{reason: "Could not load document"})}
    end
  end

  defp fetch_int(params, key) do
    case Integer.parse(to_string(Map.get(params, key, ""))) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, "#{key} must be a non-negative integer"}
    end
  end

  defp fetch_rect([x0, y0, x1, y1])
       when is_number(x0) and is_number(y0) and is_number(x1) and is_number(y1) do
    if x1 > x0 and y1 > y0 do
      {:ok, [x0 * 1.0, y0 * 1.0, x1 * 1.0, y1 * 1.0]}
    else
      {:error, :bad_rect}
    end
  end

  defp fetch_rect(_), do: {:error, :bad_rect}

  defp fetch_png(nil), do: {:error, :missing_png}

  defp fetch_png(base64) when is_binary(base64) do
    case Base.decode64(base64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :bad_png_encoding}
    end
  end

  defp load_saved_signatures(socket) do
    user_id = socket.assigns.current_scope.user.id
    signatures = Quire.Accounts.list_saved_signatures(user_id)
    assign(socket, :signatures, signatures)
  end

  defp load_saved_initials(socket) do
    user_id = socket.assigns.current_scope.user.id
    initials = Quire.Accounts.list_saved_initials(user_id)
    assign(socket, :initials, initials)
  end

  defp load_user_settings(socket) do
    user_id = socket.assigns.current_scope.user.id

    settings = Quire.Accounts.get_user_settings(user_id)
    dismissed = settings.whiteout_warning_dismissed

    socket =
      socket
      |> assign(:whiteout_warning_dismissed, dismissed || false)
      |> assign(:scripting_enabled, settings.scripting_enabled || false)
      |> assign(:signing_date_format, settings.signing_date_format || "%Y-%m-%d")
      |> assign(:signer_name, settings.signer_name)

    push_event(socket, "set_scripting", %{enabled: settings.scripting_enabled || false})
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  defp rail_items(items, active_panel) do
    Enum.map(items, &Map.put(&1, :active, &1.id == active_panel))
  end

  # Filesystem-safe slug for exported filenames (T-078).
  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> then(&if(&1 == "", do: "document", else: &1))
  end

  # Pushes the current query plus options to the viewer hook, or clears
  # the panel locally when the query is emptied.
  defp run_search(socket) do
    if socket.assigns.search_query == "" do
      socket
      |> stream(:search_results, [], reset: true)
      |> assign(:search_pages, [])
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
    pages = socket.assigns.search_pages

    if pages == [] do
      socket
    else
      index = rem(socket.assigns.search_current + delta + length(pages), length(pages))

      page = Enum.at(pages, index) |> max(1) |> min(socket.assigns.total_pages)

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

  # ── Edit-mode helpers (pdf-8vsn, pdf-un45) ─────────────────────────────

  @doc false
  # Finds the text run closest to the click position (x, y in PDF points).
  # Returns the run or nil if no run contains or is near the point.
  defp find_run_at_click(runs, x, y) do
    # Fallback: find the run with the closest center
    Enum.find(runs, fn run ->
      [x0, y0, x1, y1] = run.bbox
      x >= x0 and x <= x1 and y >= y0 and y <= y1
    end) ||
      Enum.min_by(runs, fn run ->
        [x0, y0, x1, y1] = run.bbox
        cx = (x0 + x1) / 2
        cy = (y0 + y1) / 2
        :math.sqrt((x - cx) ** 2 + (y - cy) ** 2)
      end)
  rescue
    _ -> nil
  end

  defp coerce_id(id) when is_binary(id), do: id
  defp coerce_id(id) when is_integer(id), do: Integer.to_string(id)

  attr :ocr_running, :boolean, default: false
  attr :ocr_progress, :map, default: nil

  defp ocr_options_panel(assigns) do
    ~H"""
    <div
      class="border-b border-chrome-border dark:border-gray-600 bg-chrome-white dark:bg-gray-800 shadow-sm"
      role="region"
      aria-label="OCR options panel"
    >
      <div class="max-w-md mx-auto">
        <.live_component
          module={QuireWeb.OcrOptionsLive}
          id="ocr-options"
          user_id={@current_scope.user.id}
          ocr_running={@ocr_running}
          ocr_progress={@ocr_progress}
        />
      </div>
    </div>
    """
  end

  attr :ocr_result, :any, default: nil
  attr :ocr_running, :boolean, default: false

  defp ocr_confidence_panel(assigns) do
    ~H"""
    <div
      class="border-b border-chrome-border dark:border-gray-600 bg-chrome-white dark:bg-gray-800 shadow-sm"
      role="region"
      aria-label="OCR confidence report"
    >
      <div class="max-w-md mx-auto">
        <.live_component
          module={QuireWeb.OcrConfidenceLive}
          id="ocr-confidence"
          ocr_result={@ocr_result}
          ocr_running={@ocr_running}
        />
      </div>
    </div>
    """
  end

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
  attr :form_detect_running, :boolean, default: false
  attr :form_detect_progress, :integer, default: nil
  attr :form_detections, :list, default: []
  attr :clipboard_fallback, :boolean, default: false
  attr :clipboard_fallback_msg, :string, default: nil

  @view_toggle_tabs ~w(edit comment secure forms esign ocr)

  defp ribbon_strip(assigns) do
    assigns =
      assigns
      |> assign(:view_toggle_tabs, @view_toggle_tabs)
      |> assign_new(:show_ocr_options, fn -> false end)
      |> assign_new(:ocr_running, fn -> false end)
      |> assign_new(:image_ocr_uploading, fn -> false end)
      |> assign_new(:image_ocr_error, fn -> nil end)
      |> assign_new(:show_camera_capture, fn -> false end)
      |> assign_new(:scan_progress, fn -> nil end)
      |> assign_new(:scan_error, fn -> nil end)
      |> assign_new(:ocr_progress, fn -> nil end)
      |> assign_new(:whiteout_mode_active, fn -> false end)
      |> assign_new(:builtin_stamps, fn -> [] end)
      |> assign_new(:selected_stamp_id, fn -> nil end)
      |> assign_new(:attachment_mode_active, fn -> false end)
      |> assign_new(:callout_mode_active, fn -> false end)
      |> assign_new(:stamp_mode_active, fn -> false end)
      |> assign_new(:measure_mode_active, fn -> false end)
      |> assign_new(:active_measure_mode, fn -> nil end)
      |> assign_new(:calibrating, fn -> false end)
      |> assign_new(:convert_running, fn -> false end)
      |> assign_new(:convert_format, fn -> nil end)
      |> assign_new(:convert_error, fn -> nil end)
      |> assign_new(:clipboard_fallback, fn -> false end)
      |> assign_new(:clipboard_fallback_msg, fn -> nil end)
      |> assign_new(:has_form_fields, fn -> false end)
      |> assign_new(:translate_source, fn -> "detect" end)
      |> assign_new(:translate_target, fn -> "en" end)
      |> assign_new(:translate_mode, fn -> "overlay" end)
      |> assign_new(:translate_provider_label, fn -> nil end)
      |> assign_new(:translate_results, fn -> [] end)

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

      <!-- View tab OCR tools -->
      <div :if={@active_tab == "view"} class="flex items-center gap-1 flex-1">
        <.ribbon_group label="Tools">
          <.ribbon_button
            icon="hero-document-magnifying-glass"
            label="OCR Options"
            active={@show_ocr_options}
            phx-click="toggle_ocr_options"
            has_dropdown={true}
            tooltip="Configure OCR languages and options"
            disabled={@ocr_running}
          />
          <.ribbon_button
            icon="hero-photo"
            label="Image OCR"
            phx-click="upload_image_ocr"
            tooltip="Upload an image (PNG/JPEG/WebP) and create a searchable PDF via OCR"
            disabled={@image_ocr_uploading}
          />
          <.ribbon_button
            icon="hero-camera"
            label="Scan"
            phx-click="open_camera_capture"
            tooltip="Scan a document with your device camera or a photo — deskewed and contrast-corrected PDF"
            disabled={@show_camera_capture || @scan_progress != nil}
          />
        </.ribbon_group>

        <.ribbon_group :if={@ocr_progress} label="Progress">
          <div class="flex items-center gap-2 px-2 py-1 text-xs text-gray-500">
            <.icon name="hero-arrow-path" class="size-3.5 animate-spin" />
            <span>{"#{@ocr_progress.pct}%"}</span>
          </div>
        </.ribbon_group>

        <.ribbon_group :if={@image_ocr_uploading} label="Image OCR">
          <div class="flex items-center gap-2 px-2 py-1 text-xs text-gray-500">
            <.icon name="hero-arrow-path" class="size-3.5 animate-spin" />
            <span>Processing…</span>
          </div>
        </.ribbon_group>

        <.ribbon_group :if={@image_ocr_error} label="Image OCR">
          <div class="flex items-center gap-2 px-2 py-1 text-xs text-red-500">
            <.icon name="hero-exclamation-circle" class="size-3.5" />
            <span>{error_message(@image_ocr_error)}</span>
          </div>
        </.ribbon_group>

        <.ribbon_group :if={@scan_progress} label="Scan">
          <div class="flex items-center gap-2 px-2 py-1 text-xs">
            <.icon name="hero-arrow-path" class="size-3.5 animate-spin text-accent" />
            <span class="text-gray-500 dark:text-gray-400">{@scan_progress.pct}%</span>
            <span :if={@scan_progress.message} class="text-gray-400 dark:text-gray-500">
              {@scan_progress.message}
            </span>
          </div>
          <button
            type="button"
            phx-click="cancel_scan"
            aria-label="Cancel scanning"
            class="ml-1 inline-flex items-center gap-1 px-2 py-1 text-xs rounded-md border border-chrome-border dark:border-gray-600 text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors cursor-pointer"
          >
            <.icon name="hero-x-mark" class="size-3" />
            <span>Cancel</span>
          </button>
        </.ribbon_group>

        <.ribbon_group :if={@scan_error} label="Scan">
          <div class="flex items-center gap-2 px-2 py-1 text-xs text-red-500">
            <.icon name="hero-exclamation-circle" class="size-3.5" />
            <span>{error_message(@scan_error)}</span>
          </div>
        </.ribbon_group>
      </div>

      <!-- Comment tab ribbon groups (T-107) -->
      <div :if={@active_tab == "comment"} class="flex items-center gap-1 flex-1">
        <.ribbon_group label="Shapes">
          <.ribbon_button
            icon="hero-stop"
            label="Whiteout"
            active={@whiteout_mode_active}
            phx-click="toggle_annot_mode"
            phx-value-mode="whiteout"
            tooltip="Whiteout — covers content visually"
          />
        </.ribbon_group>

        <.ribbon_group label="Stamps">
          <.ribbon_button
            :for={stamp <- @builtin_stamps}
            icon="hero-stamp"
            label={stamp.label}
            active={@selected_stamp_id == stamp.id}
            phx-click="select_builtin_stamp"
            phx-value-stamp_id={stamp.id}
            tooltip={stamp.label}
          />
          <.ribbon_split_button
            icon="hero-photo"
            label="Custom"
            phx-click="toggle_custom_stamps"
            tooltip="Custom stamps"
          />
        </.ribbon_group>

        <.ribbon_group label="Attachment">
          <.ribbon_button
            icon="hero-paper-clip"
            label="Attach File"
            active={@attachment_mode_active}
            phx-click="toggle_annot_mode"
            phx-value-mode="file_attachment"
            tooltip="Embed file attachment"
          />
          <.ribbon_button
            icon="hero-arrow-down-tray"
            label="Extract"
            phx-click="open_attachments_panel"
            tooltip="Extract attachments"
          />
        </.ribbon_group>

        <.ribbon_group label="Callout">
          <.ribbon_button
            icon="hero-chat-bubble-oval-left-ellipsis"
            label="Callout"
            active={@callout_mode_active}
            phx-click="toggle_annot_mode"
            phx-value-mode="free_text_callout"
            tooltip="Free-text callout with leader line"
          />
          <.ribbon_button
            icon="hero-stamp"
            label="Stamp"
            active={@stamp_mode_active}
            phx-click="toggle_annot_mode"
            phx-value-mode="stamp"
            tooltip="Place a stamp"
          />
        </.ribbon_group>

        <.ribbon_group label="Measure">
          <.ribbon_button
            icon="hero-ruler"
            label="Distance"
            active={@measure_mode_active && @active_measure_mode == "measure_distance"}
            phx-click="toggle_annot_mode"
            phx-value-mode="measure_distance"
            tooltip="Measure distance between two points"
          />
          <.ribbon_button
            icon="hero-arrows-right-left"
            label="Perimeter"
            active={@measure_mode_active && @active_measure_mode == "measure_perimeter"}
            phx-click="toggle_annot_mode"
            phx-value-mode="measure_perimeter"
            tooltip="Measure perimeter of a polygon"
          />
          <.ribbon_button
            icon="hero-square-2-stack"
            label="Area"
            active={@measure_mode_active && @active_measure_mode == "measure_area"}
            phx-click="toggle_annot_mode"
            phx-value-mode="measure_area"
            tooltip="Measure area of a polygon"
          />
          <.ribbon_button
            icon="hero-scale"
            label="Calibrate"
            active={@calibrating}
            phx-click="calibrate_scale"
            tooltip="Calibrate measurement scale"
          />
        </.ribbon_group>
      </div>

      <!-- Page tab ribbon (T-061 / pdf-dfdt) -->
      <div :if={@active_tab == "page"} class="flex items-center gap-1 flex-1">
        <.ribbon_group label="Insert">
          <.ribbon_button
            icon="hero-document-plus"
            label="From File"
            phx-click="insert_from_file"
            tooltip="Insert pages from another PDF file"
          />
        </.ribbon_group>

        <.ribbon_group label="Organize">
          <.ribbon_button
            icon="hero-arrows-right-left"
            label="Reorder"
            tooltip="Drag to reorder pages (in thumbnail panel)"
          />
          <.ribbon_button
            icon="hero-trash"
            label="Delete"
            tooltip="Delete selected pages"
          />
        </.ribbon_group>
      </div>

      <!-- Create & Convert tab ribbon (T-074 / pdf-wyh.1) -->
      <div :if={@active_tab == "create-convert"} class="flex items-center gap-1 flex-1">
        <.ribbon_group label="Create from…">
          <.ribbon_button
            icon="hero-clipboard-document-list"
            label="Clipboard"
            phx-hook="ClipboardPdf"
            id="clipboard-pdf-btn"
            tooltip="Create a PDF from the text or image on your clipboard"
          />
          <.ribbon_button
            icon="hero-document-plus"
            label="Merge"
            phx-click="open_merge_wizard"
            tooltip="Combine multiple PDFs — drag to reorder, per-file page ranges, bookmarks and forms options"
          />
          <.ribbon_button
            icon="hero-scissors"
            label="Split"
            phx-click="open_split_wizard"
            tooltip="Split the document into a ZIP — every N pages, at bookmarks, by ranges, by file size, or extract selected pages"
          />
          <.ribbon_button
            icon="hero-arrow-down-tray"
            label="Compress"
            phx-click="open_compress_wizard"
            tooltip="Recompress embedded images (Low/Medium/High/Custom) with a before/after size comparison and page preview"
          />
        </.ribbon_group>

        <.ribbon_group :if={@clipboard_fallback} label="Paste target">
          <div
            id="clipboard-paste-target"
            phx-hook="ClipboardPasteTarget"
            class="w-72 px-2 py-1"
          >
            <p class="text-[10px] text-gray-400 dark:text-gray-500 mb-1 leading-tight">
              {@clipboard_fallback_msg}
            </p>
            <textarea
              id="clipboard-paste-textarea"
              rows="3"
              phx-update="ignore"
              class="w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 p-2 text-xs text-gray-700 dark:text-gray-200 resize-none"
              placeholder="Paste text or an image here, or type text…"
            >
            </textarea>
            <div class="flex items-center gap-2 mt-1.5">
              <button
                type="button"
                data-clipboard-convert
                class="px-2.5 py-1 rounded-md bg-accent text-white text-[11px] font-medium hover:opacity-90"
              >
                Convert
              </button>
              <button
                type="button"
                phx-click="clipboard_pdf_cancel"
                class="px-2.5 py-1 rounded-md text-[11px] text-gray-500 hover:bg-gray-100 dark:hover:bg-gray-700"
              >
                Cancel
              </button>
            </div>
          </div>
        </.ribbon_group>

        <.ribbon_group label="Export to…">
          <.ribbon_button
            icon="hero-document-text"
            label="DOCX"
            phx-click="convert_to_office"
            phx-value-format="docx"
            tooltip="Word document (.docx) — best for text-based PDFs"
            disabled={@convert_running}
          />
          <.ribbon_button
            icon="hero-table-cells"
            label="XLSX"
            phx-click="convert_to_office"
            phx-value-format="xlsx"
            tooltip="Excel workbook (.xlsx) — best for tabular data"
            disabled={@convert_running}
          />
          <.ribbon_button
            icon="hero-presentation-chart-bar"
            label="PPTX"
            phx-click="convert_to_office"
            phx-value-format="pptx"
            tooltip="PowerPoint presentation (.pptx) — best for text-based PDFs"
            disabled={@convert_running}
          />
          <.ribbon_button
            icon="hero-code-bracket"
            label="HTML"
            phx-click="convert_to_html"
            phx-value-mode="overlay"
            tooltip="Web page (.html) — page images with selectable text, single self-contained file"
            disabled={@convert_running}
          />
          <.ribbon_button
            icon="hero-document-arrow-down"
            label="HTML text"
            phx-click="convert_to_html"
            phx-value-mode="text_only"
            tooltip="Web page (.html) — text only, reflowed, no page images"
            disabled={@convert_running}
          />
        </.ribbon_group>

        <p class="text-[10px] text-gray-400 dark:text-gray-500 italic max-w-xs leading-tight">
          Best-effort conversion; formatting fidelity depends on the source PDF.
          Run OCR first if the document has no text layer.
        </p>

        <.ribbon_group :if={@convert_running} label="Converting">
          <div class="flex items-center gap-2 px-2 py-1 text-xs text-gray-500">
            <.icon name="hero-arrow-path" class="size-3.5 animate-spin" />
            <span>{@convert_format |> String.upcase()} conversion…</span>
          </div>
        </.ribbon_group>

        <.ribbon_group :if={@convert_error} label="Error">
          <div class="flex items-center gap-2 px-2 py-1 text-xs text-red-500">
            <.icon name="hero-exclamation-circle" class="size-3.5" />
            <span>{@convert_error}</span>
          </div>
        </.ribbon_group>
      </div>

      <!-- Forms tab ribbon (T-124) -->
      <div :if={@active_tab == "forms"} class="flex items-center gap-1 flex-1">
        <.ribbon_group label="Form Actions">
          <.ribbon_button
            icon="hero-arrow-uturn-left"
            label="Reset Form"
            phx-click="reset_form"
            tooltip="Reset all form fields to their default values"
            disabled={!@has_form_fields}
          />
        </.ribbon_group>
        <.ribbon_group label="Scanned Form">
          <div class="flex items-center gap-2">
            <.ribbon_button
              icon="hero-sparkles"
              label="Auto-create fields"
              phx-click="auto_create_fields"
              tooltip="Detect form-like boxes and lines in a scanned document"
              disabled={@form_detect_running || @form_detections != nil}
            />
            <div
              :if={@form_detect_running}
              class="flex items-center gap-1.5 text-xs text-gray-500 dark:text-gray-400"
            >
              <.icon name="hero-arrow-path" class="size-3.5 animate-spin" />
              Detecting… {@form_detect_progress && @form_detect_progress.pct}%
            </div>
          </div>
        </.ribbon_group>
      </div>

      <!-- Detected-fields preview panel (T-125) -->
      <div
        :if={@form_detections != nil}
        class="border-t border-gray-200 dark:border-gray-700 bg-amber-50 dark:bg-amber-950/30 px-4 py-2 flex items-center gap-3"
        id="form-detection-preview"
      >
        <span class="text-sm text-amber-900 dark:text-amber-200">
          Detected {@form_detections.total} field(s) — check the highlighted boxes, then accept or discard.
        </span>
        <button
          type="button"
          phx-click="accept_detected_fields"
          class="ml-auto text-xs font-medium rounded-md px-2.5 py-1 bg-emerald-600 hover:bg-emerald-700 text-white transition-colors"
        >
          Accept
        </button>
        <button
          type="button"
          phx-click="discard_detected_fields"
          class="text-xs font-medium rounded-md px-2.5 py-1 border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
        >
          Discard
        </button>
      </div>

      <!-- Translate tab ribbon (T-157) -->
      <div :if={@active_tab == "translate"} class="flex items-center gap-1 flex-1">
        <.ribbon_group label="Languages">
          <div class="flex items-center gap-2 px-2">
            <select
              phx-change="translate_set_source"
              class="text-xs border border-gray-300 dark:border-gray-600 rounded px-1.5 py-1 bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100"
              aria-label="Source language"
              value={@translate_source}
            >
              <option value="detect">Detect</option>
              <option value="en">English</option>
              <option value="es">Spanish</option>
              <option value="fr">French</option>
              <option value="de">German</option>
              <option value="it">Italian</option>
              <option value="pt">Portuguese</option>
              <option value="nl">Dutch</option>
              <option value="pl">Polish</option>
              <option value="ru">Russian</option>
              <option value="ja">Japanese</option>
              <option value="ko">Korean</option>
              <option value="zh">Chinese</option>
              <option value="ar">Arabic</option>
            </select>
            <.icon name="hero-arrow-right" class="size-3.5 text-gray-400" />
            <select
              phx-change="translate_set_target"
              class="text-xs border border-gray-300 dark:border-gray-600 rounded px-1.5 py-1 bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100"
              aria-label="Target language"
              value={@translate_target}
            >
              <option value="en">English</option>
              <option value="es">Spanish</option>
              <option value="fr">French</option>
              <option value="de">German</option>
              <option value="it">Italian</option>
              <option value="pt">Portuguese</option>
              <option value="nl">Dutch</option>
              <option value="pl">Polish</option>
              <option value="ru">Russian</option>
              <option value="ja">Japanese</option>
              <option value="ko">Korean</option>
              <option value="zh">Chinese</option>
              <option value="ar">Arabic</option>
            </select>
          </div>
        </.ribbon_group>

        <.ribbon_group label="Mode">
          <div class="flex items-center gap-1 px-2">
            <button
              type="button"
              phx-click="translate_set_mode"
              phx-value-mode="overlay"
              class={[
                "px-2.5 py-1 rounded text-xs font-medium transition-colors",
                if(@translate_mode == "overlay",
                  do: "bg-accent text-white",
                  else:
                    "bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600"
                )
              ]}
            >
              Overlay
            </button>
            <button
              type="button"
              phx-click="translate_set_mode"
              phx-value-mode="sidecar"
              class={[
                "px-2.5 py-1 rounded text-xs font-medium transition-colors",
                if(@translate_mode == "sidecar",
                  do: "bg-accent text-white",
                  else:
                    "bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600"
                )
              ]}
            >
              Sidecar
            </button>
            <button
              type="button"
              phx-click="translate_set_mode"
              phx-value-mode="replace"
              class={[
                "px-2.5 py-1 rounded text-xs font-medium transition-colors",
                if(@translate_mode == "replace",
                  do: "bg-accent text-white",
                  else:
                    "bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600"
                )
              ]}
            >
              Replace
            </button>
          </div>
        </.ribbon_group>

        <.ribbon_group label="Action">
          <.ribbon_button
            icon="hero-language"
            label="Translate"
            phx-click="translate_document"
            tooltip="Translate the document using the configured provider"
          />
        </.ribbon_group>

        <.ribbon_group :if={@translate_provider_label} label="Provider">
          <div class="flex items-center gap-1.5 px-2 py-1 text-xs text-gray-500 dark:text-gray-400">
            <.icon name="hero-information-circle" class="size-3.5" />
            <span>{@translate_provider_label}</span>
          </div>
        </.ribbon_group>
      </div>

      <!-- E-Sign tab ribbon (T-147) -->
      <div :if={@active_tab == "esign"} class="flex items-center gap-1 flex-1">
        <.ribbon_group label="Request">
          <.ribbon_button
            icon="hero-envelope"
            label="Request Signature"
            phx-click="open_esign_wizard"
            tooltip="Create and send a signature request"
          />
        </.ribbon_group>
      </div>

      <div :if={
        @active_tab not in @view_toggle_tabs and @active_tab != "create-convert" and
          @active_tab != "page" and @active_tab != "esign" and @active_tab != "translate"
      }>
        <p class="text-sm text-gray-400 dark:text-gray-500 italic px-4">
          Select a tool
        </p>
      </div>
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
  attr :signatures, :list, default: []
  attr :initials, :list, default: []
  attr :search_query, :string, default: ""
  attr :search_results, :list, default: []
  attr :translate_results, :list, default: []
  attr :search_total, :integer, default: 0
  attr :search_current, :integer, default: 0
  attr :search_match_case, :boolean, default: false
  attr :search_whole_word, :boolean, default: false
  attr :searching, :boolean, default: false
  attr :active_document_id, :string, default: nil
  attr :current_user_id, :any, default: nil

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
        <% @panel == :signatures -> %>
          <.signatures_panel slot="signature" signatures={@signatures} />
        <% @panel == :initials -> %>
          <.signatures_panel slot="initials" signatures={@initials} />
        <% @panel == :confidence -> %>
          <.ocr_confidence_panel />
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
        <% @panel == :translate -> %>
          <div class="flex-1 overflow-y-auto p-4 space-y-3">
            <%= if @translate_results == [] do %>
              <p class="text-sm text-gray-400 dark:text-gray-500">
                No translations yet. Select a language pair and click Translate.
              </p>
            <% else %>
              <div class="space-y-3">
                <%= for result <- @translate_results do %>
                  <div class="border border-gray-200 dark:border-gray-700 rounded-lg overflow-hidden">
                    <div class="bg-gray-50 dark:bg-gray-750 px-3 py-1.5 text-xs font-medium text-gray-500 dark:text-gray-400 border-b border-gray-200 dark:border-gray-700">
                      Page {result.page}
                    </div>
                    <%= if result.error do %>
                      <div class="p-3 text-xs text-red-500">
                        Error: {result.error}
                      </div>
                    <% else %>
                      <div class="p-3 space-y-2">
                        <div class="text-xs text-gray-400 dark:text-gray-500">
                          {String.slice(result.original, 0, 200)}{if String.length(result.original) >
                                                                       200,
                                                                     do: "…"}
                        </div>
                        <%= if result.translated do %>
                          <div class="text-xs text-gray-900 dark:text-gray-100 font-medium border-t border-gray-100 dark:border-gray-700 pt-2">
                            {String.slice(result.translated, 0, 200)}{if String.length(
                                                                           result.translated
                                                                         ) > 200, do: "…"}
                          </div>
                        <% end %>
                        <%= if result.banner do %>
                          <div class="text-xs text-amber-600 dark:text-amber-400 italic">
                            {result.banner}
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% @panel == :comments -> %>
          <.live_component
            module={QuireWeb.Live.CommentsPanel}
            id="comments-panel"
            document_id={@active_document_id}
            current_user_id={@current_scope.user.id}
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
  defp panel_title(:signatures), do: "Signatures"
  defp panel_title(:initials), do: "Initials"
  defp panel_title(:comments), do: "Comments"
  defp panel_title(:translate), do: "Translate"

  defp provider_label do
    provider = Quire.Translation.Provider.configured()
    mod = provider |> Module.split() |> Enum.join(".")
    "Provider: #{mod}"
  end

  defp builtin_stamps do
    [
      %{id: "approved", label: "Approved"},
      %{id: "draft", label: "Draft"},
      %{id: "confidential", label: "Confidential"},
      %{id: "reviewed", label: "Reviewed"},
      %{id: "for_public_release", label: "Public Release"},
      %{id: "sign_here", label: "Sign Here"}
    ]
  end

  # ── Helpers (T-143) ──────────────────────────────────────────────────

  defp decode_data_url("data:" <> rest) do
    # Format: data:image/jpeg;base64,/9j...
    case String.split(rest, ",", parts: 2) do
      [_, base64_data] ->
        Base.decode64!(base64_data)

      _ ->
        raise "Invalid data URL format"
    end
  end

  defp decode_data_url(binary) when is_binary(binary), do: binary

  defp cancel_scan_job(socket) do
    socket
    |> assign(:scan_progress, nil)
    |> assign(:scan_job_id, nil)
  end

  defp error_message({:invalid_image, msg}), do: msg
  defp error_message({:pipeline_error, _}), do: "OCR processing failed"
  defp error_message(nil), do: ""
  defp error_message(_), do: "An unknown error occurred"

  # ── PubSub handlers (T-139) ──────────────────────────────────────────

  @impl true
  def handle_info({:revision, rev}, socket) do
    socket =
      socket
      |> assign(:ocr_running, false)
      |> assign(:ocr_progress, nil)
      |> assign(:convert_running, false)
      |> assign(:convert_format, nil)
      |> assign(:convert_error, nil)
      |> clear_form_detection()
      |> push_event("revision_updated", %{revision_id: rev.id})

    # Fetch confidence data for this revision to show the confidence panel.
    ocr_result = OcrResults.by_revision(rev.id)

    socket =
      if ocr_result do
        socket
        |> assign(:show_ocr_confidence, true)
        |> assign(:ocr_confidence_result, ocr_result)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:operation_progress, operation_id, pct}, socket) do
    # Form-field detection jobs carry an operation_id; OCR jobs broadcast
    # with nil (never sent) — keep the legacy assign for compatibility.
    socket =
      if operation_id == socket.assigns.form_detect_operation_id do
        assign(socket, :form_detect_progress, %{pct: pct})
      else
        assign(socket, :ocr_progress, %{pct: pct})
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:auto_create_detections, operation_id, detections}, socket) do
    if operation_id == socket.assigns.form_detect_operation_id do
      {:noreply,
       socket
       |> assign(:form_detect_running, false)
       |> assign(:form_detect_progress, %{pct: 100})
       |> assign(:form_detections, detections)
       |> push_event("form_detection_preview", %{fields: detections.fields})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:run_ocr, options}, socket) do
    # Options from the LiveComponent have atom keys; convert to string keys
    # for Oban job args (JSON serialisation).
    options =
      options
      |> Enum.map(fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
      |> Map.new()

    enqueue_ocr(socket, options)
  end

  @impl true
  def handle_info({:rerun_ocr, page_list, options}, socket) do
    # Options from the LiveComponent may have atom or string keys;
    # normalise to string keys for Oban job args.
    options =
      options
      |> Enum.map(fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
      |> Map.new()

    enqueue_ocr(socket, options, page_list)
  end

  # T-110: annotation navigation from the Comments panel LiveComponent.
  @impl true
  def handle_info({:navigate_to_annotation, page_index, rect}, socket) do
    page = (page_index + 1) |> max(1) |> min(socket.assigns.total_pages)

    {:noreply,
     socket
     |> assign(:page, page)
     |> push_event("navigate_page", %{page: page})
     |> push_event("select_annotation", %{rect: rect, page_index: page_index})}
  end

  @impl true
  def handle_info({:dismiss_ocr_confidence}, socket) do
    {:noreply, assign(socket, :show_ocr_confidence, false)}
  end

  # ── Annotation export / import handlers (T-111) ────────────────────────

  @impl true
  def handle_info({:download, filename, content, content_type}, socket) do
    {:noreply,
     push_event(socket, "download", %{
       content: Base.encode64(content),
       filename: filename,
       content_type: content_type
     })}
  end

  @impl true
  def handle_info({:import_complete, count}, socket) do
    {:noreply, put_flash(socket, :info, "Imported #{count} annotations from XFDF")}
  end

  @impl true
  def handle_info({:export_error, reason}, socket) do
    {:noreply, put_flash(socket, :error, reason)}
  end

  # ── Image OCR upload handlers (T-143) ─────────────────────────────────

  @impl true
  def handle_event("upload_image_ocr", _params, socket) do
    {:noreply, push_event(socket, "trigger_image_picker", %{})}
  end

  # ── Insert-from-file handlers (T-061 / pdf-dfdt) ──────────────────────

  @impl true
  def handle_event("insert_from_file", _params, socket) do
    {:noreply, push_event(socket, "trigger_insert_pdf_picker", %{})}
  end

  @impl true
  def handle_event("insert_pdf_submit", _params, socket) do
    [%{meta: meta, bytes: insert_bytes}] =
      consume_uploaded_entries(socket, :insert_pdf, fn meta, entry ->
        %{meta: meta, bytes: File.read!(entry.path)}
      end)

    doc_id = socket.assigns.active_document_id
    scope = socket.assigns.current_scope

    case insert_pages_into_document(doc_id, scope, insert_bytes, meta.name) do
      {:ok, _rev} ->
        {:noreply,
         socket
         |> put_flash(:info, "Pages from #{meta.name} inserted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Insert failed: #{reason}")}
    end
  end

  defp check_form_fields(socket) do
    doc_id = socket.assigns.active_document_id
    scope = socket.assigns.current_scope

    with {:ok, doc} <- Quire.Documents.get_document(doc_id, scope),
         {:ok, rev} <- Quire.Documents.current_revision(doc),
         %Quire.Storage.Ref{} = ref <- Quire.Documents.Revision.storage_ref(rev),
         {:ok, doc_bytes} <- Quire.Storage.get(ref) do
      case Quire.FormData.read_defaults(doc_bytes) do
        {:ok, defaults} when map_size(defaults) > 0 -> true
        _ -> false
      end
    else
      _ -> false
    end
  end

  @impl true
  def handle_event("translate_set_source", %{"value" => source}, socket) do
    {:noreply, assign(socket, :translate_source, source)}
  end

  @impl true
  def handle_event("translate_set_target", %{"value" => target}, socket) do
    {:noreply, assign(socket, :translate_target, target)}
  end

  @impl true
  def handle_event("translate_set_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :translate_mode, mode)}
  end

  @impl true
  def handle_event("translate_document", _params, socket) do
    source = socket.assigns.translate_source
    target = socket.assigns.translate_target
    mode = socket.assigns.translate_mode

    provider = Quire.Translation.Provider.configured()

    doc_id = socket.assigns.active_document_id
    scope = socket.assigns.current_scope

    socket =
      with {:ok, doc} <- Quire.Documents.get_document(doc_id, scope),
           {:ok, rev} <- Quire.Documents.current_revision(doc),
           %Quire.Storage.Ref{} = ref <- Quire.Documents.Revision.storage_ref(rev) do
        case Quire.Render.extract_text(ref, []) do
          {:ok, page_results} ->
            translations =
              Enum.map(page_results, fn page_result ->
                text =
                  page_result.spans
                  |> Enum.map(& &1.text)
                  |> Enum.join("")

                if text != "" do
                  case provider.translate(text, source, target) do
                    {:ok, result} ->
                      %{
                        page: page_result.page + 1,
                        original: text,
                        translated: result.translated_text,
                        banner: result.banner
                      }

                    {:error, reason} ->
                      %{
                        page: page_result.page + 1,
                        original: text,
                        translated: nil,
                        error: reason
                      }
                  end
                else
                  %{page: page_result.page + 1, original: "", translated: "", error: nil}
                end
              end)

            total = length(translations)
            ok = Enum.count(translations, &(not is_nil(&1.translated)))
            errors = Enum.count(translations, &(not is_nil(&1.error)))

            socket =
              socket
              |> assign(:translate_provider_label, provider_label())
              |> assign(:translate_results, translations)
              |> assign(:right_panel, :translate)
              |> put_flash(:info, "Translation: #{ok}/#{total} pages done, #{errors} errors")

            case mode do
              "replace" ->
                source_map = %{
                  "source_revision" => rev.id,
                  "note" => "Translated #{source}→#{target}",
                  "mode" => mode,
                  "translations" => translations
                }

                with {:ok, doc_bytes} <- Quire.Storage.get(ref),
                     {:ok, new_ref} <-
                       Quire.Storage.put(doc_bytes,
                         name: doc.title,
                         content_type: "application/pdf"
                       ) do
                  source_map =
                    Map.put(source_map, "storage_ref", %{
                      "adapter" => to_string(new_ref.adapter),
                      "key" => new_ref.key,
                      "name" => new_ref.name,
                      "content_type" => new_ref.content_type,
                      "byte_size" => new_ref.byte_size
                    })

                  {:ok, _new_rev} =
                    Quire.Documents.create_revision(doc,
                      label: "Translated (#{source}→#{target})",
                      source: source_map
                    )

                  socket
                  |> push_event("open_document", %{
                    url: socket.assigns.document_url,
                    password: nil
                  })
                  |> put_flash(:info, "New revision saved with translation")
                else
                  {:error, reason} ->
                    put_flash(socket, :error, "Replace failed: #{reason}")
                end

              "overlay" ->
                overlay_data =
                  Enum.map(translations, fn t ->
                    %{page: t.page, translated: t.translated, error: t.error}
                  end)

                push_event(socket, "translate_overlay", %{pages: overlay_data})

              "sidecar" ->
                put_flash(
                  socket,
                  :info,
                  "Sidecar mode coming soon — results in the Translate panel"
                )

              _ ->
                socket
            end

          {:error, reason} ->
            put_flash(socket, :error, "Text extraction failed: #{reason}")
        end
      else
        _ ->
          put_flash(socket, :error, "Could not load document for translation")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("reset_form", _params, socket) do
    doc_id = socket.assigns.active_document_id
    scope = socket.assigns.current_scope

    with {:ok, doc} <- Quire.Documents.get_document(doc_id, scope),
         {:ok, rev} <- Quire.Documents.current_revision(doc),
         %Quire.Storage.Ref{} = ref <- Quire.Documents.Revision.storage_ref(rev),
         {:ok, doc_bytes} <- Quire.Storage.get(ref) do
      case Quire.FormData.reset(doc_bytes) do
        {:ok, reset_bytes} when is_binary(reset_bytes) ->
          {:ok, new_ref} =
            Quire.Storage.put(reset_bytes,
              name: doc.title,
              content_type: "application/pdf"
            )

          source_map = %{
            "storage_ref" => %{
              "adapter" => to_string(new_ref.adapter),
              "key" => new_ref.key,
              "name" => new_ref.name,
              "content_type" => new_ref.content_type,
              "byte_size" => new_ref.byte_size
            },
            "source_revision" => rev.id,
            "note" => "Form reset to defaults"
          }

          {:ok, _new_rev} =
            Quire.Documents.create_revision(doc,
              label: "Form reset",
              source: source_map
            )

          {:noreply,
           socket
           |> push_event("open_document", %{
             url: socket.assigns.document_url,
             password: nil
           })
           |> put_flash(:info, "Form fields reset to defaults")}

        _ ->
          {:noreply, put_flash(socket, :error, "No form fields found to reset")}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Could not load document for reset")}
    end
  end

  # ── Auto-create fields from a scanned form (T-125) ─────────────────────

  def handle_event("auto_create_fields", _params, socket) do
    doc_id = socket.assigns.active_document_id
    scope = socket.assigns.current_scope

    with {:ok, doc} <- Quire.Documents.get_document(doc_id, scope),
         {:ok, rev} <- Quire.Documents.current_revision(doc) do
      operation_id = Ecto.UUID.generate()

      args = %{
        "doc_id" => doc_id,
        "revision_id" => rev.id,
        "operation_id" => operation_id
      }

      args
      |> Quire.Workers.AutoCreateFieldsWorker.new([])
      |> Oban.insert!()

      {:noreply,
       socket
       |> assign(:form_detect_running, true)
       |> assign(:form_detect_progress, %{pct: 0})
       |> assign(:form_detect_operation_id, operation_id)
       |> assign(:form_detections, nil)
       |> put_flash(:info, "Field detection started on #{doc.title}")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start detection: #{inspect(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not load document for detection")}
    end
  end

  def handle_event("accept_detected_fields", _params, socket) do
    doc_id = socket.assigns.active_document_id
    scope = socket.assigns.current_scope
    detections = socket.assigns.form_detections

    with true <- detections != nil,
         {:ok, doc} <- Quire.Documents.get_document(doc_id, scope),
         {:ok, %{revision: _rev}} <-
           Quire.Forms.AutoCreate.commit_revision(doc, detections.fields) do
      {:noreply,
       socket
       |> clear_form_detection()
       |> put_flash(:info, "Created #{detections.total} form field(s)")}
    else
      false ->
        {:noreply, put_flash(socket, :error, "No detections to commit")}

      {:error, reason} ->
        {:noreply,
         socket
         |> clear_form_detection()
         |> put_flash(:error, "Failed to create fields: #{inspect(reason)}")}
    end
  end

  def handle_event("discard_detected_fields", _params, socket) do
    {:noreply,
     socket
     |> clear_form_detection()
     |> put_flash(:info, "Detection discarded")}
  end

  defp clear_form_detection(socket) do
    socket
    |> assign(:form_detections, nil)
    |> assign(:form_detect_running, false)
    |> assign(:form_detect_progress, nil)
    |> assign(:form_detect_operation_id, nil)
    |> push_event("form_detection_clear", %{})
  end

  defp insert_pages_into_document(doc_id, scope, insert_bytes, filename) do
    with {:ok, doc} <- Quire.Documents.get_document(doc_id, scope),
         {:ok, rev} <- Quire.Documents.current_revision(doc),
         %Quire.Storage.Ref{} = ref <- Quire.Documents.Revision.storage_ref(rev),
         {:ok, doc_bytes} <- Quire.Storage.get(ref) do
      # Merge the two PDFs via ExPdfium
      with {:ok, src_doc} <- ExPdfium.open(insert_bytes),
           {:ok, dest_doc} <- ExPdfium.open(doc_bytes) do
        try do
          with {:ok, merged} <- ExPdfium.append(dest_doc, src_doc),
               {:ok, merged_bytes} <- ExPdfium.save_to_bytes(merged) do
            # Store as new revision
            {:ok, new_ref} =
              Quire.Storage.put(merged_bytes,
                name: doc.title,
                content_type: "application/pdf"
              )

            source_map = %{
              "storage_ref" => %{
                "adapter" => to_string(new_ref.adapter),
                "key" => new_ref.key,
                "name" => new_ref.name,
                "content_type" => new_ref.content_type,
                "byte_size" => new_ref.byte_size
              },
              "source_revision" => rev.id,
              "inserted_file" => filename,
              "note" => "Pages inserted from #{filename}"
            }

            {:ok, new_rev} =
              Quire.Documents.create_revision(doc,
                label: "Inserted from #{filename}",
                source: source_map
              )

            {:ok, new_rev}
          end
        after
          ExPdfium.close(src_doc)
          ExPdfium.close(dest_doc)
        end
      end
    end
  end

  @impl true
  def handle_event("upload_image_ocr_submit", _params, socket) do
    [%{meta: meta, bytes: image_bytes}] =
      consume_uploaded_entries(socket, :image, fn meta, entry ->
        %{meta: meta, bytes: File.read!(entry.path)}
      end)

    title = Path.rootname(meta.name, Path.extname(meta.name))

    socket =
      socket
      |> assign(:image_ocr_uploading, true)
      |> assign(:image_ocr_error, nil)

    socket =
      case Quire.Workers.ImageOcrWorker.process(image_bytes, title, socket.assigns.current_scope) do
        {:ok, %{document: doc}} ->
          push_navigate(socket, to: ~p"/workspace/#{doc.id}")

        {:error, {:invalid_image, msg}} ->
          socket
          |> assign(:image_ocr_uploading, false)
          |> assign(:image_ocr_error, {:invalid_image, msg})
          |> put_flash(:error, msg)

        {:error, reason} ->
          socket
          |> assign(:image_ocr_uploading, false)
          |> assign(:image_ocr_error, {:pipeline_error, inspect(reason)})
          |> put_flash(:error, "Image OCR failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  # ── Scan (camera capture) handlers (T-144) ──────────────────────────────

  @impl true
  def handle_event("open_camera_capture", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_camera_capture, true)
     |> assign(:scan_job_id, nil)
     |> assign(:scan_progress, nil)
     |> assign(:scan_error, nil)}
  end

  @impl true
  def handle_event("close_camera_capture", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_camera_capture, false)}
  end

  @impl true
  def handle_event("cancel_scan", _params, socket) do
    socket = cancel_scan_job(socket)

    {:noreply,
     socket
     |> assign(:scan_job_id, nil)
     |> assign(:scan_progress, nil)
     |> assign(:scan_error, nil)
     |> put_flash(:info, "Scan cancelled.")}
  end

  # ── Camera capture event handlers (forwarded from hook → parent LV) ───

  @impl true
  def handle_event("camera_captured", %{"dataUrl" => data_url}, socket) do
    send_update(QuireWeb.CameraCaptureComponent,
      id: "camera-capture",
      phase: :captured,
      captured_data_url: data_url
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("camera_ready_event", _params, socket) do
    send_update(QuireWeb.CameraCaptureComponent,
      id: "camera-capture",
      phase: :capturing
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("camera_error_event", %{"message" => msg}, socket) do
    send_update(QuireWeb.CameraCaptureComponent,
      id: "camera-capture",
      phase: :error,
      error_message: msg
    )

    {:noreply, socket}
  end

  # ── Scan processing (T-080): camera capture + file input both land here
  # with the same image bytes and options, and both feed the same image→PDF
  # path (Quire.Scan). The "make searchable" option additionally OCRs (T-144).
  # ─────────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:scan_image, data_url, title, opts}, socket) do
    image_bytes = decode_data_url(data_url)
    {:noreply, process_scan(socket, image_bytes, title || "Scan", opts)}
  end

  # Camera capture with a plain 3-tuple (legacy callers) — defaults to a
  # plain scan-to-PDF, no OCR.
  @impl true
  def handle_info({:scan_image, data_url, title}, socket) do
    image_bytes = decode_data_url(data_url)
    {:noreply, process_scan(socket, image_bytes, title || "Scan", %{})}
  end

  # File input with camera capture (the .ScanFileInput colocated hook).
  @impl true
  def handle_event("scan_file_ready", params, socket) do
    image_bytes = decode_data_url(params["dataUrl"])

    opts = %{
      deskew: params["deskew"] != "false",
      contrast: params["contrast"] || "auto",
      ocr: params["ocr"] == "true"
    }

    {:noreply, process_scan(socket, image_bytes, params["title"] || "Scan", opts)}
  end

  defp process_scan(socket, image_bytes, title, opts) do
    socket =
      socket
      |> assign(:show_camera_capture, false)
      |> assign(:scan_job_id, nil)
      |> assign(:scan_error, nil)
      |> assign(:scan_progress, %{pct: 0, message: "Building PDF…"})

    if Map.get(opts, :ocr, false) do
      process_ocr_scan(socket, image_bytes, title)
    else
      process_pdf_scan(socket, image_bytes, title, opts)
    end
  end

  defp process_pdf_scan(socket, image_bytes, title, opts) do
    deskew? = Map.get(opts, :deskew, true)
    contrast = scan_contrast(Map.get(opts, :contrast, "auto"))

    case Quire.Scan.image_to_pdf(image_bytes, deskew: deskew?, contrast: contrast) do
      {:ok, pdf_bytes} ->
        case Quire.Documents.ingest(pdf_bytes, socket.assigns.current_scope, title: title) do
          {:ok, %{document: doc}} ->
            socket
            |> assign(:scan_progress, %{pct: 100, message: "Complete!"})
            |> push_navigate(to: ~p"/workspace/#{doc.id}")

          {:error, reason} ->
            socket
            |> assign(:scan_progress, nil)
            |> assign(:scan_error, {:pipeline_error, inspect(reason)})
            |> put_flash(:error, "Scan failed: #{inspect(reason)}")
        end

      {:error, {:invalid_image, msg}} ->
        socket
        |> assign(:scan_progress, nil)
        |> assign(:scan_error, {:invalid_image, msg})
        |> put_flash(:error, msg)

      {:error, reason} ->
        socket
        |> assign(:scan_progress, nil)
        |> assign(:scan_error, {:pipeline_error, inspect(reason)})
        |> put_flash(:error, "Scan failed: #{inspect(reason)}")
    end
  end

  # T-144: optional "make searchable" step keeps the OCR pipeline behind the
  # same scan entry point.
  defp process_ocr_scan(socket, image_bytes, title) do
    socket = assign(socket, :scan_progress, %{pct: 0, message: "Running OCR…"})

    case Quire.Workers.ImageOcrWorker.process(image_bytes, title, socket.assigns.current_scope) do
      {:ok, %{document: doc}} ->
        socket
        |> assign(:scan_progress, %{pct: 100, message: "Complete!"})
        |> push_navigate(to: ~p"/workspace/#{doc.id}")

      {:error, {:invalid_image, msg}} ->
        socket
        |> assign(:scan_progress, nil)
        |> assign(:scan_error, {:invalid_image, msg})
        |> put_flash(:error, msg)

      {:error, reason} ->
        socket
        |> assign(:scan_progress, nil)
        |> assign(:scan_error, {:pipeline_error, inspect(reason)})
        |> put_flash(:error, "Scan OCR failed: #{inspect(reason)}")
    end
  end

  # Contrast arrives as a string from the UI; map it onto the fixed preset
  # atoms only (never String.to_atom on user input).
  defp scan_contrast("none"), do: :none
  defp scan_contrast("high"), do: :high
  defp scan_contrast("low"), do: :low
  defp scan_contrast("bw"), do: :bw
  defp scan_contrast(_), do: :auto

  # ── Merge wizard (T-081) ──────────────────────────────────────────────

  @merge_max_files 12
  @merge_max_bytes 200_000_000

  @impl true
  def handle_event("open_merge_wizard", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_merge_wizard, true)
     |> assign(:merge_error, nil)
     |> assign(:merge_running, false)}
  end

  @impl true
  def handle_event("close_merge_wizard", _params, socket) do
    {:noreply, assign(socket, :show_merge_wizard, false)}
  end

  # auto_upload: true — fired as soon as files are selected/dropped.
  @impl true
  def handle_event("merge_files", _params, socket) do
    entries =
      consume_uploaded_entries(socket, :merge_files, fn file_meta, entry ->
        %{name: entry.client_name, bytes: File.read!(file_meta.path)}
      end)

    socket =
      Enum.reduce_while(entries, socket, fn file, acc ->
        cond do
          length(acc.assigns.merge_files) >= @merge_max_files ->
            {:halt, put_flash(acc, :error, "Merge supports at most #{@merge_max_files} files")}

          true ->
            pages =
              case ExPdfium.open(file.bytes) do
                {:ok, doc} ->
                  case ExPdfium.page_count(doc) do
                    {:ok, n} -> n
                    _ -> 0
                  end

                _ ->
                  0
              end

            if pages == 0 do
              {:halt, put_flash(acc, :error, "#{file.name} is not a readable PDF")}
            else
              item = %{
                id: Ecto.UUID.generate(),
                name: file.name,
                bytes: file.bytes,
                pages: pages,
                range: ""
              }

              {:cont,
               acc
               |> assign(:merge_files, acc.assigns.merge_files ++ [item])
               |> assign(:merge_error, nil)}
            end
        end
      end)

    {:noreply, socket}
  end

  # The range input is named by the item's id (the browser's change event
  # sends %{item_id => range}); handle the generic shape defensively.
  @impl true
  def handle_event("merge_set_range", params, socket) do
    {id, range} =
      case Map.to_list(params) do
        [{id, range}] -> {id, range}
        _ -> {nil, nil}
      end

    if is_binary(id) and is_binary(range) do
      files =
        Enum.map(
          socket.assigns.merge_files,
          &if(&1.id == id, do: %{&1 | range: range}, else: &1)
        )

      {:noreply, socket |> assign(:merge_files, files) |> assign(:merge_error, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("merge_move_file", %{"id" => id, "dir" => dir}, socket) do
    {:noreply, move_merge_file(socket, id, dir)}
  end

  # HTML5 drag-and-drop reorder: move `id` to the position of `target`.
  @impl true
  def handle_event("merge_move_file", %{"id" => id, "dir" => "to", "target" => target}, socket) do
    files = socket.assigns.merge_files
    ids = Enum.map(files, & &1.id)

    with true <- id in ids,
         true <- target in ids,
         from when is_integer(from) <- Enum.find_index(ids, &(&1 == id)),
         to when is_integer(to) <- Enum.find_index(ids, &(&1 == target)) do
      {item, rest} = List.pop_at(files, from)
      moved = List.insert_at(rest, to, item)
      {:noreply, assign(socket, :merge_files, moved)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("merge_remove_file", %{"id" => id}, socket) do
    files = Enum.reject(socket.assigns.merge_files, &(&1.id == id))
    {:noreply, socket |> assign(:merge_files, files) |> assign(:merge_error, nil)}
  end

  @impl true
  def handle_event("merge_toggle_numbering", _params, socket) do
    {:noreply, update(socket, :merge_numbering, &(!&1))}
  end

  @impl true
  def handle_event("merge_set_bookmarks", %{"bookmarks" => value}, socket) do
    {:noreply, assign(socket, :merge_bookmarks, value)}
  end

  @impl true
  def handle_event("merge_set_forms", %{"forms" => value}, socket) do
    {:noreply, assign(socket, :merge_forms, value)}
  end

  @impl true
  def handle_event("merge_submit", _params, socket) do
    if socket.assigns.merge_files == [] do
      {:noreply, put_flash(socket, :error, "Add at least one PDF to merge")}
    else
      {:noreply, run_merge(socket)}
    end
  end

  defp run_merge(socket) do
    socket = socket |> assign(:merge_running, true) |> assign(:merge_error, nil)

    case build_merge_sources(socket.assigns.merge_files) do
      {:ok, sources} ->
        opts = [
          continue_numbering: socket.assigns.merge_numbering,
          bookmarks: merge_choice(socket.assigns.merge_bookmarks, :keep),
          forms: merge_choice(socket.assigns.merge_forms, :keep)
        ]

        case Quire.Merge.merge_and_ingest(sources, opts, socket.assigns.current_scope,
               title: "Merged PDF"
             ) do
          {:ok, %{document: doc}} ->
            journal_doc_merge(doc, sources, opts)

            socket
            |> assign(:merge_running, false)
            |> assign(:show_merge_wizard, false)
            |> assign(:merge_files, [])
            |> put_flash(:info, "Merged #{length(sources)} PDF(s) into #{doc.title}")
            |> push_navigate(to: ~p"/workspace/#{doc.id}")

          {:error, reason} ->
            socket
            |> assign(:merge_running, false)
            |> assign(:merge_error, merge_error_message(reason))
            |> put_flash(:error, merge_error_message(reason))
        end

      {:error, message} ->
        socket
        |> assign(:merge_running, false)
        |> assign(:merge_error, message)
        |> put_flash(:error, message)
    end
  end

  # Resolves each file's range spec against its page count; fails with a
  # plain-language message on the first bad spec.
  defp build_merge_sources(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case Quire.Merge.parse_ranges(file.range, file.pages) do
        {:ok, pages} ->
          {:cont, {:ok, acc ++ [%{bytes: file.bytes, pages: pages}]}}

        {:error, {message, _spec}} ->
          {:halt, {:error, "#{file.name}: #{message}"}}
      end
    end)
  end

  # Best-effort doc.merge journal entry on the new document's edit session.
  # Plain map (not the Operation struct) — EditSession.apply reads it with
  # both Map.get/2 and Access, which structs do not implement.
  defp journal_doc_merge(doc, sources, opts) do
    user_id = doc.user_id

    with {:ok, session} <- Quire.Editing.open_session(doc.id, user_id) do
      op = %{
        kind: "doc.merge",
        data: %{sources: Enum.map(sources, &%{pages: &1.pages}), opts: opts},
        inverse: {:restore_revision, nil}
      }

      Quire.Editing.apply_for_server(session, op)
    end
  end

  defp merge_choice("flatten", _default), do: :flatten
  defp merge_choice("discard", _default), do: :discard
  defp merge_choice(_, default), do: default

  defp merge_error_message({:too_many_sources, n, max}), do: "Too many sources: #{n} (max #{max})"

  defp merge_error_message({:page_out_of_bounds, _pages, count}),
    do: "Page selection out of range (document has #{count} pages)"

  defp merge_error_message(:no_sources), do: "Nothing to merge"
  defp merge_error_message(:missing_bytes), do: "A source PDF could not be read"
  defp merge_error_message({:invalid_pdf, _}), do: "One of the files is not a valid PDF"
  defp merge_error_message(reason), do: "Merge failed: #{inspect(reason)}"

  defp move_merge_file(socket, id, "up") do
    files = socket.assigns.merge_files
    idx = Enum.find_index(files, &(&1.id == id))

    if is_integer(idx) and idx > 0 do
      {item, rest} = List.pop_at(files, idx)
      assign(socket, :merge_files, List.insert_at(rest, idx - 1, item))
    else
      socket
    end
  end

  defp move_merge_file(socket, id, "down") do
    files = socket.assigns.merge_files
    idx = Enum.find_index(files, &(&1.id == id))

    if is_integer(idx) and idx < length(files) - 1 do
      {item, rest} = List.pop_at(files, idx)
      assign(socket, :merge_files, List.insert_at(rest, idx + 1, item))
    else
      socket
    end
  end

  defp move_merge_file(socket, _id, _other), do: socket

  defp merge_upload_error(:too_large), do: "File too large (max 50 MB)"
  defp merge_upload_error(:too_many_files), do: "Too many files (max 12)"
  defp merge_upload_error(:not_accepted), do: "Only PDF files are accepted"
  defp merge_upload_error(_), do: "Upload failed"

  # ── Split wizard (T-082) ──────────────────────────────────────────────

  @impl true
  def handle_event("open_split_wizard", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_split_wizard, true)
     |> assign(:split_mode, "every_n")
     |> assign(:split_n, "5")
     |> assign(:split_level, "1")
     |> assign(:split_ranges, "")
     |> assign(:split_size, "1mb")
     |> assign(:split_extract, "")
     |> assign(:split_running, false)
     |> assign(:split_error, nil)}
  end

  @impl true
  def handle_event("close_split_wizard", _params, socket) do
    {:noreply, assign(socket, :show_split_wizard, false)}
  end

  @impl true
  def handle_event("split_set_mode", %{"mode" => mode}, socket) do
    {:noreply, socket |> assign(:split_mode, mode) |> assign(:split_error, nil)}
  end

  @impl true
  def handle_event("split_set_param", params, socket) do
    socket =
      Enum.reduce(params, socket, fn
        {"n", value}, acc -> assign(acc, :split_n, value)
        {"level", value}, acc -> assign(acc, :split_level, value)
        {"ranges", value}, acc -> assign(acc, :split_ranges, value)
        {"size", value}, acc -> assign(acc, :split_size, value)
        {"extract", value}, acc -> assign(acc, :split_extract, value)
        _, acc -> acc
      end)

    {:noreply, assign(socket, :split_error, nil)}
  end

  @impl true
  def handle_event("split_submit", _params, socket) do
    {:noreply, run_split(socket)}
  end

  defp run_split(socket) do
    socket = socket |> assign(:split_running, true) |> assign(:split_error, nil)

    with {:ok, doc} <-
           Quire.Documents.get_document(
             socket.assigns.active_document_id,
             socket.assigns.current_scope
           ),
         {:ok, rev} <- Quire.Documents.current_revision(doc),
         ref when not is_nil(ref) <- Quire.Documents.Revision.storage_ref(rev),
         {:ok, bytes} <- Quire.Storage.get(ref),
         {:ok, mode} <- build_split_mode(socket.assigns),
         {:ok, outputs} <-
           Quire.Split.split(bytes, mode, name: split_prefix(socket.assigns.split_mode)),
         {:ok, zip_bytes} <- Quire.Split.zip_outputs(outputs, "split.zip") do
      journal_doc_split(doc, mode, length(outputs))

      socket
      |> assign(:split_running, false)
      |> assign(:show_split_wizard, false)
      |> push_event("download", %{
        content: Base.encode64(zip_bytes),
        filename: "split.zip",
        content_type: "application/zip"
      })
      |> put_flash(:info, "Split into #{length(outputs)} PDF(s) — split.zip downloaded")
    else
      {:error, reason} ->
        message = split_error_message(reason)

        socket
        |> assign(:split_running, false)
        |> assign(:split_error, message)
        |> put_flash(:error, message)

      nil ->
        socket
        |> assign(:split_running, false)
        |> assign(:split_error, "No current document to split")
        |> put_flash(:error, "No current document to split")
    end
  end

  defp build_split_mode(assigns) do
    case assigns.split_mode do
      "every_n" ->
        case Integer.parse(assigns.split_n) do
          {n, ""} when n >= 1 -> {:ok, {:every_n, n}}
          _ -> {:error, "Enter a positive page count (every N pages)"}
        end

      "bookmarks" ->
        case Integer.parse(assigns.split_level) do
          {level, ""} when level >= 1 -> {:ok, {:bookmarks, level}}
          _ -> {:error, "Enter a positive bookmark level"}
        end

      "ranges" ->
        with {:ok, count} <- split_page_count(assigns),
             {:ok, groups} <- Quire.Split.parse_range_groups(assigns.split_ranges, count) do
          {:ok, {:ranges, groups}}
        end

      "file_size" ->
        case split_size_bytes(assigns.split_size) do
          {:ok, bytes} -> {:ok, {:file_size, bytes}}
          {:error, _} -> {:error, "Choose a target file size"}
        end

      "extract" ->
        with {:ok, count} <- split_page_count(assigns) do
          case parse_page_list(assigns.split_extract, count) do
            {:ok, pages} -> {:ok, {:extract, pages}}
            {:error, message} -> {:error, message}
          end
        end

      other ->
        {:error, "Unknown split mode: #{other}"}
    end
  end

  defp split_page_count(assigns) do
    with {:ok, doc} <-
           Quire.Documents.get_document(assigns.active_document_id, assigns.current_scope),
         {:ok, rev} <- Quire.Documents.current_revision(doc),
         ref when not is_nil(ref) <- Quire.Documents.Revision.storage_ref(rev),
         {:ok, bytes} <- Quire.Storage.get(ref),
         {:ok, pdf_doc} <- ExPdfium.open(bytes) do
      ExPdfium.page_count(pdf_doc)
    else
      _ -> {:error, :no_document}
    end
  end

  # comma-separated 1-based pages → 0-based indices
  defp parse_page_list(spec, count) do
    trimmed = String.trim(spec)

    if trimmed == "" do
      {:error, "Enter the pages to extract (e.g. 1,4,7)"}
    else
      trimmed
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
        case Integer.parse(part) do
          {n, ""} when n >= 1 and n <= count -> {:cont, {:ok, acc ++ [n - 1]}}
          {n, ""} -> {:halt, {:error, "page #{n} is out of range (document has #{count} pages)"}}
          _ -> {:halt, {:error, "invalid page number \"#{part}\""}}
        end
      end)
    end
  end

  defp split_size_bytes("100kb"), do: {:ok, 100_000}
  defp split_size_bytes("500kb"), do: {:ok, 500_000}
  defp split_size_bytes("1mb"), do: {:ok, 1_000_000}
  defp split_size_bytes("5mb"), do: {:ok, 5_000_000}
  defp split_size_bytes("10mb"), do: {:ok, 10_000_000}
  defp split_size_bytes("50mb"), do: {:ok, 50_000_000}
  defp split_size_bytes(_), do: {:error, :unknown_size}

  defp split_prefix("extract"), do: "extract"
  defp split_prefix(_), do: "part"

  defp split_error_message({:no_bookmarks, _}), do: "The document has no bookmarks at that level"

  defp split_error_message({:page_out_of_bounds, _, count}),
    do: "Page selection out of range (document has #{count} pages)"

  defp split_error_message({:unknown_mode, mode}), do: "Unknown split mode: #{inspect(mode)}"
  defp split_error_message({:zip_failed, reason}), do: "ZIP packaging failed: #{inspect(reason)}"
  defp split_error_message(:empty_ranges), do: "Enter at least one page range"
  defp split_error_message(:no_document), do: "No current document to split"
  defp split_error_message(reason), do: "Split failed: #{inspect(reason)}"

  # Best-effort doc.split journal entry on the source document's session.
  defp journal_doc_split(doc, mode, output_count) do
    with {:ok, session} <- Quire.Editing.open_session(doc.id, doc.user_id) do
      op = %{
        kind: "doc.split",
        data: %{mode: mode, output_count: output_count},
        inverse: {:restore_revision, nil}
      }

      Quire.Editing.apply_for_server(session, op)
    end
  end

  # ── Compress wizard (T-083) ───────────────────────────────────────────

  @impl true
  def handle_event("open_compress_wizard", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_compress_wizard, true)
     |> assign(:compress_preset, "medium")
     |> assign(:compress_custom_quality, "60")
     |> assign(:compress_custom_max_width, "2048")
     |> assign(:compress_remove_a11y, false)
     |> assign(:compress_running, false)
     |> assign(:compress_error, nil)
     |> assign(:compress_preview, nil)}
  end

  @impl true
  def handle_event("close_compress_wizard", _params, socket) do
    {:noreply, assign(socket, :show_compress_wizard, false)}
  end

  @impl true
  def handle_event("compress_set_preset", %{"preset" => preset}, socket) do
    {:noreply,
     socket
     |> assign(:compress_preset, preset)
     |> assign(:compress_error, nil)
     |> assign(:compress_preview, nil)}
  end

  @impl true
  def handle_event("compress_set_param", params, socket) do
    socket =
      Enum.reduce(params, socket, fn
        {"quality", value}, acc -> assign(acc, :compress_custom_quality, value)
        {"max_width", value}, acc -> assign(acc, :compress_custom_max_width, value)
        _, acc -> acc
      end)

    {:noreply, socket |> assign(:compress_error, nil) |> assign(:compress_preview, nil)}
  end

  @impl true
  def handle_event("compress_toggle_a11y", _params, socket) do
    {:noreply, update(socket, :compress_remove_a11y, &(!&1))}
  end

  @impl true
  def handle_event("compress_preview", _params, socket) do
    {:noreply, run_compress_preview(socket)}
  end

  @impl true
  def handle_event("compress_commit", _params, socket) do
    {:noreply, run_compress_commit(socket)}
  end

  defp run_compress_preview(socket) do
    socket = socket |> assign(:compress_running, true) |> assign(:compress_error, nil)

    with {:ok, doc} <-
           Quire.Documents.get_document(
             socket.assigns.active_document_id,
             socket.assigns.current_scope
           ),
         {:ok, rev} <- Quire.Documents.current_revision(doc),
         ref when not is_nil(ref) <- Quire.Documents.Revision.storage_ref(rev),
         {:ok, bytes} <- Quire.Storage.get(ref),
         {:ok, opts} <- compress_opts(socket.assigns),
         {:ok, out} <- Quire.Compress.compress(bytes, opts) do
      preview = %{
        before_size: byte_size(bytes),
        after_size: byte_size(out),
        pct: percent_smaller(byte_size(bytes), byte_size(out)),
        before_png: preview_png(bytes),
        after_png: preview_png(out)
      }

      socket
      |> assign(:compress_running, false)
      |> assign(:compress_preview, preview)
    else
      {:error, reason} ->
        socket
        |> assign(:compress_running, false)
        |> assign(:compress_error, compress_error_message(reason))

      nil ->
        socket
        |> assign(:compress_running, false)
        |> assign(:compress_error, "No current document to compress")
    end
  end

  defp run_compress_commit(socket) do
    socket = socket |> assign(:compress_running, true) |> assign(:compress_error, nil)

    with {:ok, doc} <-
           Quire.Documents.get_document(
             socket.assigns.active_document_id,
             socket.assigns.current_scope
           ),
         {:ok, rev} <- Quire.Documents.current_revision(doc),
         ref when not is_nil(ref) <- Quire.Documents.Revision.storage_ref(rev),
         {:ok, bytes} <- Quire.Storage.get(ref),
         {:ok, opts} <- compress_opts(socket.assigns),
         {:ok, out} <- Quire.Compress.compress(bytes, opts) do
      case save_compressed_revision(doc, out) do
        {:ok, %{rev: new_rev}} ->
          journal_doc_compress(doc, opts, byte_size(bytes), byte_size(out))

          socket
          |> assign(:compress_running, false)
          |> assign(:show_compress_wizard, false)
          |> assign(:compress_preview, nil)
          |> assign(:document_url, "/documents/#{doc.id}/pdf?rev=#{new_rev.id}")
          |> put_flash(
            :info,
            "Compressed #{format_bytes(byte_size(bytes))} → #{format_bytes(byte_size(out))} (#{percent_smaller(byte_size(bytes), byte_size(out))}% smaller)"
          )

        {:error, reason} ->
          socket
          |> assign(:compress_running, false)
          |> assign(:compress_error, compress_error_message(reason))
      end
    else
      {:error, reason} ->
        socket
        |> assign(:compress_running, false)
        |> assign(:compress_error, compress_error_message(reason))

      nil ->
        socket
        |> assign(:compress_running, false)
        |> assign(:compress_error, "No current document to compress")
    end
  end

  defp compress_opts(assigns) do
    preset =
      case assigns.compress_preset do
        "low" -> :low
        "high" -> :high
        "custom" -> :custom
        _ -> :medium
      end

    opts = [preset: preset, remove_accessibility: assigns.compress_remove_a11y]

    if preset == :custom do
      with {:ok, q} <- parse_pos_int(assigns.compress_custom_quality),
           {:ok, w} <- parse_pos_int(assigns.compress_custom_max_width) do
        {:ok, Keyword.merge(opts, quality: q, max_width: w)}
      else
        _ -> {:error, :custom_params}
      end
    else
      {:ok, opts}
    end
  end

  defp parse_pos_int(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp preview_png(bytes) do
    with {:ok, doc} <- ExPdfium.open(bytes),
         {:ok, bitmap} <- ExPdfium.render_page(doc, 0, dpi: 96) do
      base64_png(bitmap)
    else
      _ -> nil
    end
  end

  defp base64_png(%ExPdfium.Bitmap{} = bitmap) do
    {bands, format} = bitmap_format(bitmap.format)

    with {:ok, img} <-
           Vix.Vips.Image.new_from_binary(bitmap.data, bitmap.width, bitmap.height, bands, format),
         {:ok, png} <- Vix.Vips.Image.write_to_buffer(img, ".png") do
      "data:image/png;base64," <> Base.encode64(png)
    else
      _ -> nil
    end
  end

  defp bitmap_format(:gray), do: {1, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(:rgb), do: {3, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(:bgr), do: {3, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(:rgba), do: {4, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(:bgrx), do: {4, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(:cmyk), do: {4, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(_), do: {3, :VIPS_FORMAT_UCHAR}

  defp percent_smaller(before, after_size) when before > 0 do
    round((before - after_size) * 100 / before)
  end

  defp percent_smaller(_, _), do: 0

  defp format_bytes(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)} MB"
  defp format_bytes(n) when n >= 1_000, do: "#{round(n / 1_000)} KB"
  defp format_bytes(n), do: "#{n} B"

  defp save_compressed_revision(doc, out_bytes) do
    with {:ok, new_ref} <-
           Quire.Storage.put(out_bytes,
             name: doc.title,
             content_type: "application/pdf"
           ) do
      source_map = %{
        "storage_ref" => %{
          "adapter" => to_string(new_ref.adapter),
          "key" => new_ref.key,
          "name" => new_ref.name,
          "content_type" => new_ref.content_type,
          "byte_size" => new_ref.byte_size
        },
        "source_revision" => doc.current_revision_id,
        "note" => "Compressed"
      }

      with {:ok, new_rev} <-
             Quire.Documents.create_revision(doc, label: "Compressed", source: source_map) do
        {:ok, linked} =
          doc
          |> Ecto.Changeset.change(%{current_revision_id: new_rev.id})
          |> Quire.Repo.update()

        {:ok, %{rev: new_rev, doc: linked}}
      end
    end
  end

  defp journal_doc_compress(doc, opts, before, after_size) do
    with {:ok, session} <- Quire.Editing.open_session(doc.id, doc.user_id) do
      op = %{
        kind: "doc.compress",
        data: %{opts: opts, before_bytes: before, after_bytes: after_size},
        inverse: {:restore_revision, nil}
      }

      Quire.Editing.apply_for_server(session, op)
    end
  end

  defp compress_error_message(:custom_params),
    do: "Custom quality and max width must be positive numbers"

  defp compress_error_message(reason), do: "Compress failed: #{inspect(reason)}"

  @impl true
  def handle_info({:close_camera_modal}, socket) do
    {:noreply, assign(socket, :show_camera_capture, false)}
  end

  @impl true
  def handle_info({:request_camera}, socket) do
    {:noreply, push_event(socket, "start_camera", %{})}
  end

  # ── Annotation commit helpers (T-107) ────────────────────────────────

  defp handle_annotation_commit(socket, document_id, type, data) do
    user_id = socket.assigns.current_scope.user.id

    # For measure types, embed the computed measurement alongside path data
    path_data =
      case type do
        kind when kind in ~w(measure_distance measure_perimeter measure_area) ->
          %{
            geometry: data["pathData"] || data["path_data"],
            measurement: data["measurement"],
            cal_factor: data["calFactor"],
            cal_unit: data["calUnit"]
          }

        _ ->
          data["pathData"] || data["path_data"]
      end

    annot = %{
      revision_id: document_id,
      page_index: data["pageIndex"] || 0,
      kind: type,
      rect: data["rectPdf"] || data["rect"],
      path_data: path_data,
      color: data["color"] || data["strokeColor"] || data["fillColor"],
      opacity: data["opacity"] || Map.get(data, "opacity", 100),
      border_width: data["strokeWidth"] || data["borderWidth"] || data["border_width"],
      content: data["content"] || data["text"],
      author: socket.assigns.current_scope.user.name || user_id
    }

    record_annotation(socket, document_id, user_id, annot)
  end

  defp handle_stamp_commit(socket, document_id, data) do
    user_id = socket.assigns.current_scope.user.id

    annot = %{
      revision_id: document_id,
      page_index: data["pageIndex"] || 0,
      kind: "stamp",
      rect: data["rectPdf"] || data["rect"],
      content: data["stampId"] || "custom",
      path_data: data["stampSvg"],
      color: nil,
      opacity: 100,
      author: socket.assigns.current_scope.user.name || user_id
    }

    record_annotation(socket, document_id, user_id, annot)
  end

  defp handle_callout_commit(socket, document_id, data) do
    user_id = socket.assigns.current_scope.user.id

    annot = %{
      revision_id: document_id,
      page_index: data["pageIndex"] || 0,
      kind: "free_text_callout",
      rect: data["rectPdf"] || data["rect"],
      path_data: data["anchor"] || data["anchorPdf"],
      content: data["content"] || "",
      color: data["color"],
      opacity: 100,
      border_width: 1,
      author: socket.assigns.current_scope.user.name || user_id
    }

    record_annotation(socket, document_id, user_id, annot)
  end

  defp handle_file_attachment_commit(socket, document_id, data) do
    user_id = socket.assigns.current_scope.user.id

    # File bytes come from the client as base64.
    # Store via Quire.Storage and reference by ref.
    file_data = data["fileData"]
    file_name = data["fileName"] || "attachment"
    file_type = data["fileType"] || "application/octet-stream"

    attachment_ref =
      if file_data do
        bytes =
          case Base.decode64(file_data) do
            {:ok, decoded} -> decoded
            _ -> file_data
          end

        case Quire.Storage.put(bytes, name: file_name, content_type: file_type) do
          {:ok, ref} -> ref
          _ -> nil
        end
      end

    annot = %{
      revision_id: document_id,
      page_index: data["pageIndex"] || 0,
      kind: "file_attachment",
      rect: data["rectPdf"] || data["rect"],
      attachment_ref:
        attachment_ref &&
          %{
            key: attachment_ref.key,
            name: attachment_ref.name,
            content_type: attachment_ref.content_type,
            byte_size: attachment_ref.byte_size
          },
      content: file_name,
      color: nil,
      opacity: 100,
      author: socket.assigns.current_scope.user.name || user_id
    }

    record_annotation(socket, document_id, user_id, annot)
  end

  defp record_annotation(socket, document_id, user_id, annot) do
    with {:ok, session_pid} <- Quire.Editing.open_session(document_id, user_id),
         {:ok, _} <-
           Quire.Editing.apply(session_pid, %{
             kind: "annot.add",
             data: annot
           }) do
      assign(socket, :mutations_pending, true)
    else
      _ ->
        put_flash(socket, :error, "Failed to record annotation")
    end
  end

  defp no_document_placeholder(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-3 text-center select-none">
      <.icon name="hero-document" class="size-12 text-gray-300 dark:text-gray-600" />
      <p class="text-sm text-gray-400 dark:text-gray-500">No document open</p>
    </div>
    """
  end

  attr :measure_modal_open, :boolean, required: true
  attr :calibrating, :boolean, required: true
  attr :cal_known_length, :string, required: true
  attr :cal_known_unit, :string, required: true
  attr :cal_drawn_points, :any, default: nil

  defp calibration_modal(assigns) do
    ~H"""
    <.modal title="Scale Calibration" open={@measure_modal_open} on_close="close_calibration_modal">
      <div class="space-y-4">
        <p class="text-sm text-gray-600 dark:text-gray-400">
          Calibrate the measurement scale by drawing a reference line on the document
          and entering its known real-world length.
        </p>

        <div class="flex items-center gap-3">
          <button
            type="button"
            phx-click="begin_calibration_draw"
            disabled={@calibrating}
            class={[
              "flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium transition-colors",
              if(@calibrating,
                do: "bg-green-100 text-green-700 border border-green-300 cursor-default",
                else: "bg-accent text-white hover:bg-accent/90 cursor-pointer"
              )
            ]}
          >
            {if @calibrating, do: "Drawing… Click & drag on document", else: "Draw Reference Line"}
          </button>

          <span :if={@cal_drawn_points} class="text-sm text-gray-500">
            Drawn: <strong>{Float.round(@cal_drawn_points, 1)} pt</strong>
          </span>
        </div>

        <div class="border-t border-chrome-border dark:border-gray-600 pt-4">
          <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            Known real-world length
          </label>
          <div class="flex items-center gap-2">
            <input
              type="number"
              step="any"
              min="0"
              value={@cal_known_length}
              phx-change="update_cal_length"
              placeholder="e.g. 5"
              class="w-24 px-3 py-1.5 text-sm border border-chrome-border dark:border-gray-600 rounded-lg bg-chrome-white dark:bg-gray-800 text-gray-900 dark:text-gray-100"
            />
            <select
              phx-change="update_cal_unit"
              class="px-3 py-1.5 text-sm border border-chrome-border dark:border-gray-600 rounded-lg bg-chrome-white dark:bg-gray-800 text-gray-900 dark:text-gray-100"
            >
              <option value="mm" selected={@cal_known_unit == "mm"}>mm</option>
              <option value="cm" selected={@cal_known_unit == "cm"}>cm</option>
              <option value="inches" selected={@cal_known_unit == "inches"}>inches</option>
              <option value="meters" selected={@cal_known_unit == "meters"}>meters</option>
              <option value="points" selected={@cal_known_unit == "points"}>points</option>
            </select>
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <button
            type="button"
            phx-click="close_calibration_modal"
            class="px-4 py-2 text-sm text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="apply_calibration"
            disabled={!@cal_drawn_points}
            class={[
              "px-4 py-2 text-sm font-medium rounded-lg transition-colors",
              if(@cal_drawn_points,
                do: "bg-accent text-white hover:bg-accent/90 cursor-pointer",
                else: "bg-gray-200 text-gray-400 cursor-not-allowed dark:bg-gray-700"
              )
            ]}
          >
            Apply
          </button>
        </div>
      </div>
    </.modal>
    """
  end
end
