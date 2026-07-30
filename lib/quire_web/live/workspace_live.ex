defmodule QuireWeb.WorkspaceLive do
  @moduledoc """
  The workspace shell (plan3.md §8.1): a single LiveView that owns the
  title bar, menu bar, ribbon, document tab strip, side rails and
  collapsible panels, and the status bar, so the chrome and document
  state stay in lockstep without PubSub round trips.

  Mounted at `/workspace/:id` for authenticated users. Wired here: menu
  bar tab selection, rail panel toggles, and page navigation. Document
  loading and the multi-document tab strip (T-032), the per-tab ribbon
  LiveComponents (§9), and the backstage overlay (T-036) build on this
  shell — their controls render as inert placeholders until then.
  """
  use QuireWeb, :live_view

  import QuireWeb.Chrome.DocumentTabs, only: [document_tabs: 1]
  import QuireWeb.Chrome.MenuBar, only: [menu_bar: 1]
  import QuireWeb.Chrome.Rail, only: [rail: 1]
  import QuireWeb.Chrome.StatusBar, only: [status_bar: 1]
  import QuireWeb.Chrome.TitleBar, only: [title_bar: 1]

  @left_rail_items [
    %{id: :thumbnails, icon: "hero-squares-2x2", label: "Thumbnails"},
    %{id: :bookmarks, icon: "hero-bookmark", label: "Bookmarks"}
  ]

  @right_rail_items [
    %{id: :search, icon: "hero-magnifying-glass", label: "Search"},
    %{id: :attachments, icon: "hero-paper-clip", label: "Attachments"}
  ]

  @panels [:thumbnails, :bookmarks, :search, :attachments]

  @impl true
  def mount(%{"id" => _id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Workspace")
      |> assign(:document_title, nil)
      |> assign(:documents, [])
      |> assign(:active_document_id, nil)
      |> assign(:active_tab, "view")
      |> assign(:left_panel, nil)
      |> assign(:right_panel, nil)
      |> assign(:page, 1)
      |> assign(:total_pages, 1)
      |> assign(:zoom, 100)
      |> assign(:read_only?, false)
      |> assign(:progress, nil)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:left_items, rail_items(@left_rail_items, assigns.left_panel))
      |> assign(:right_items, rail_items(@right_rail_items, assigns.right_panel))

    ~H"""
    <Layouts.workspace flash={@flash}>
      <.title_bar document_title={@document_title} />
      <.menu_bar active_tab={@active_tab} on_tab_click="select_tab" />
      <.ribbon_strip />
      <.document_tabs documents={@documents} active_id={@active_document_id} />

      <div class="flex flex-1 min-h-0">
        <.rail side="left" items={@left_items} on_item_click="toggle_panel" />
        <.side_panel :if={@left_panel} side="left" panel={@left_panel} />

        <main
          id="document-canvas"
          class="flex-1 min-w-0 flex items-center justify-center"
          aria-label="Document canvas"
        >
          <.no_document_placeholder />
        </main>

        <.side_panel :if={@right_panel} side="right" panel={@right_panel} />
        <.rail side="right" items={@right_items} on_item_click="toggle_panel" />
      </div>

      <.status_bar
        page={@page}
        total_pages={@total_pages}
        zoom={@zoom}
        progress={@progress}
        on_prev_page="prev_page"
        on_next_page="next_page"
      />
    </Layouts.workspace>
    """
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
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

  def handle_event("prev_page", _params, socket) do
    {:noreply, assign(socket, :page, max(socket.assigns.page - 1, 1))}
  end

  def handle_event("next_page", _params, socket) do
    {:noreply, assign(socket, :page, min(socket.assigns.page + 1, socket.assigns.total_pages))}
  end

  defp rail_items(items, active_panel) do
    Enum.map(items, &Map.put(&1, :active, &1.id == active_panel))
  end

  # The ribbon renders the active tab's LiveComponent (plan3.md §8.1);
  # those land with the §9 feature tickets. Until then the strip holds
  # its 84 px (`chrome-ribbon` token) with a hint.
  defp ribbon_strip(assigns) do
    ~H"""
    <div
      class="chrome-ribbon flex items-center px-4 bg-chrome-white dark:bg-gray-800 border-b border-chrome-border dark:border-gray-600"
      role="toolbar"
      aria-label="Ribbon"
    >
      <p class="text-sm text-gray-400 dark:text-gray-500 italic px-4">Select a tool</p>
    </div>
    """
  end

  attr :side, :string, values: ["left", "right"], required: true
  attr :panel, :atom, required: true

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
      <div class="flex-1 overflow-y-auto p-4">
        <p class="text-sm text-gray-400 dark:text-gray-500">{panel_hint(@panel)}</p>
      </div>
    </aside>
    """
  end

  defp panel_title(:thumbnails), do: "Thumbnails"
  defp panel_title(:bookmarks), do: "Bookmarks"
  defp panel_title(:search), do: "Search"
  defp panel_title(:attachments), do: "Attachments"

  defp panel_hint(:thumbnails), do: "Open a document to browse its page thumbnails here."
  defp panel_hint(:bookmarks), do: "Open a document to read and manage its outline bookmarks."
  defp panel_hint(:search), do: "Open a document to search its text."
  defp panel_hint(:attachments), do: "Open a document to list its embedded attachments."

  defp no_document_placeholder(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-3 text-center select-none">
      <.icon name="hero-document" class="size-12 text-gray-300 dark:text-gray-600" />
      <p class="text-sm text-gray-400 dark:text-gray-500">No document open</p>
    </div>
    """
  end
end
