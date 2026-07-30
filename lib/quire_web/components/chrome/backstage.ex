defmodule QuireWeb.Chrome.Backstage do
  @moduledoc """
  Full-window Backstage (File menu) overlay (plan3.md §10.2).

  A full-screen overlay inside `WorkspaceLive` with an accent-coloured
  back arrow top-left. The left rail lists: New, Open, Save, Save as,
  Save optimized, Properties, Print, Print selection, Exit. Clicking
  Open reveals a source column (Recent / Computer / Add account);
  clicking Computer shows the Computer pane with Browse and Local
  Folders.

  The component is stateless — its open/closed state and the active
  backstage view are managed by the parent WorkspaceLive assigns.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  @rail_items [
    %{id: "new", icon: "hero-document-plus", label: "New"},
    %{id: "open", icon: "hero-folder-open", label: "Open"},
    %{id: "save", icon: "hero-cloud-arrow-down", label: "Save"},
    %{id: "save-as", icon: "hero-document-duplicate", label: "Save as"},
    %{id: "save-optimized", icon: "hero-arrow-down-tray", label: "Save optimized"},
    %{id: "properties", icon: "hero-information-circle", label: "Properties"},
    %{id: "print", icon: "hero-printer", label: "Print"},
    %{id: "print-selection", icon: "hero-printer", label: "Print selection"},
    %{id: "exit", icon: "hero-arrow-left-on-rectangle", label: "Exit"}
  ]

  @source_items [
    %{id: "recent", icon: "hero-clock", label: "Recent"},
    %{id: "computer", icon: "hero-computer-desktop", label: "Computer"},
    %{id: "add-account", icon: "hero-plus-circle", label: "Add account"}
  ]

  @local_folders [
    %{id: "desktop", label: "Desktop"},
    %{id: "documents", label: "Documents"},
    %{id: "downloads", label: "Downloads"},
    %{id: "app-files", label: "App Files"},
    %{id: "current-location", label: "Current Document Location"}
  ]

  attr :open, :boolean, default: false
  attr :active_view, :string, default: nil
  attr :dirty, :boolean, default: false
  attr :on_select, :any, default: nil
  attr :on_close, :any, default: nil

  def backstage(assigns) do
    assigns =
      assigns
      |> assign(:rail_items, @rail_items)

    ~H"""
    <div
      :if={@open}
      id="backstage-overlay"
      class="fixed inset-0 z-[100] bg-chrome-white dark:bg-gray-900 flex select-none"
      role="dialog"
      aria-modal="true"
      aria-label="Backstage"
    >
      <!-- Left rail -->
      <div class="w-56 flex flex-col border-r border-chrome-border dark:border-gray-600 shrink-0">
        <div class="flex items-center gap-3 px-4 h-14 border-b border-chrome-border dark:border-gray-600">
          <button
            type="button"
            phx-click={@on_close}
            aria-label="Close backstage"
            class="p-1.5 -ml-1.5 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
          >
            <.icon name="hero-arrow-left" class="size-5 text-accent" />
          </button>
          <span class="text-sm font-semibold text-gray-900 dark:text-gray-100">File</span>
        </div>

        <nav class="flex-1 py-2 overflow-y-auto" aria-label="Backstage commands">
          <.rail_item
            :for={item <- @rail_items}
            item={item}
            active={@active_view == item.id}
            disabled={item.id in ~w(save save-as save-optimized) && !@dirty}
            on_click={@on_select}
          />
        </nav>
      </div>

      <!-- Content area -->
      <div class="flex-1 flex overflow-hidden">
        <%= cond do %>
          <% @active_view in ~w(open computer recent add-account) -> %>
            <.source_column
              active_source={@active_view}
              on_select={@on_select}
            />
            <%= if @active_view == "computer" do %>
              <.computer_pane />
            <% else %>
              <.source_hint view={@active_view} />
            <% end %>
          <% true -> %>
            <.default_view />
        <% end %>
      </div>
    </div>
    """
  end

  # ── Left rail item ──────────────────────────────────────────────────────

  attr :item, :map, required: true
  attr :active, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :on_click, :any, default: nil

  defp rail_item(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={if !@disabled, do: @on_click}
      phx-value-view={@item.id}
      disabled={@disabled}
      aria-current={if @active, do: "page"}
      class={[
        "w-full flex items-center gap-3 px-4 py-2.5 text-sm transition-colors",
        if(@active,
          do: "bg-accent/10 text-accent font-medium border-r-2 border-accent",
          else: "text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"
        ),
        if(@disabled, do: "opacity-40 cursor-not-allowed", else: "cursor-pointer")
      ]}
    >
      <.icon name={@item.icon} class="size-4 shrink-0" />
      <span>{@item.label}</span>
    </button>
    """
  end

  # ── Default view (shown when no rail item is active) ────────────────────

  defp default_view(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center">
        <.icon name="hero-document" class="size-16 text-gray-200 dark:text-gray-700 mx-auto mb-4" />
        <p class="text-sm text-gray-400 dark:text-gray-500">Select an option from the File menu</p>
      </div>
    </div>
    """
  end

  # ── Source column (shown when Open or a source is selected) ─────────────

  attr :active_source, :string, default: nil
  attr :on_select, :any, default: nil

  defp source_column(assigns) do
    assigns =
      assigns
      |> assign(:source_items, @source_items)

    ~H"""
    <div class="w-56 flex flex-col border-r border-chrome-border dark:border-gray-600 shrink-0 bg-gray-50 dark:bg-gray-800/50">
      <h2 class="px-4 py-3 text-sm font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
        Source
      </h2>
      <nav class="flex-1 px-2" aria-label="Sources">
        <.source_item
          :for={item <- @source_items}
          item={item}
          active={@active_source == item.id}
          on_click={@on_select}
        />
      </nav>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :active, :boolean, default: false
  attr :on_click, :any, default: nil

  defp source_item(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@on_click}
      phx-value-view={@item.id}
      aria-current={if @active, do: "page"}
      class={[
        "w-full flex items-center gap-3 px-3 py-2.5 text-sm rounded-lg transition-colors cursor-pointer",
        if(@active,
          do: "bg-accent/10 text-accent font-medium",
          else: "text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700"
        )
      ]}
    >
      <.icon name={@item.icon} class="size-4 text-gray-500 dark:text-gray-400 shrink-0" />
      <span>{@item.label}</span>
    </button>
    """
  end

  # ── Source hint (shown when a source is selected but not Computer) ──────

  defp source_hint(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center max-w-sm">
        <.icon
          name={
            case @view do
              "recent" -> "hero-clock"
              "add-account" -> "hero-plus-circle"
              _ -> "hero-folder-open"
            end
          }
          class="size-16 text-gray-200 dark:text-gray-700 mx-auto mb-4"
        />
        <p class="text-sm text-gray-400 dark:text-gray-500">
          <%= case @view do %>
            <% "recent" -> %>
              Recent documents will appear here
            <% "add-account" -> %>
              Connect a cloud account to browse files
            <% _ -> %>
              Select a source or browse your computer
          <% end %>
        </p>
      </div>
    </div>
    """
  end

  # ── Computer pane ──────────────────────────────────────────────────────

  defp computer_pane(assigns) do
    assigns =
      assigns
      |> assign(:local_folders, @local_folders)

    ~H"""
    <div class="flex-1 p-8 overflow-y-auto">
      <h2 class="text-base font-semibold text-gray-900 dark:text-gray-100 mb-1">
        Open from Computer
      </h2>
      <p class="text-sm text-gray-500 dark:text-gray-400 mb-6">
        Browse your local files or select a folder
      </p>

      <!-- Browse button — opens the native file dialog via hidden input -->
      <div class="mb-8">
        <form phx-change="backstage_upload">
          <label class="inline-flex items-center gap-2 px-5 py-2.5 bg-accent text-white text-sm font-medium rounded-lg hover:bg-accent/90 transition-colors cursor-pointer">
            <.icon name="hero-folder-open" class="size-4" />
            <span>Browse…</span>
            <input type="file" name="file" accept=".pdf,application/pdf" class="hidden" />
          </label>
        </form>
      </div>

      <!-- Breadcrumb -->
      <div class="flex items-center gap-1.5 text-sm text-gray-500 dark:text-gray-400 mb-4">
        <.icon name="hero-chevron-up" class="size-3" />
        <span class="text-gray-700 dark:text-gray-300 font-medium">This PC</span>
      </div>

      <!-- Local Folders -->
      <div class="mb-6">
        <h3 class="text-xs font-semibold text-gray-400 dark:text-gray-500 uppercase tracking-wider mb-2 px-1">
          Local Folders
        </h3>
        <div class="space-y-0.5">
          <.folder_item
            :for={folder <- @local_folders}
            folder={folder}
          />
        </div>
      </div>

      <!-- Devices and drives (web build: not populated) -->
      <div>
        <h3 class="text-xs font-semibold text-gray-400 dark:text-gray-500 uppercase tracking-wider mb-2 px-1">
          Devices and drives
        </h3>
        <p class="text-xs text-gray-400 dark:text-gray-500 px-1 italic">
          Connected devices and cloud storage appear here
        </p>
      </div>
    </div>
    """
  end

  attr :folder, :map, required: true

  defp folder_item(assigns) do
    ~H"""
    <button
      type="button"
      class="w-full flex items-center gap-3 px-3 py-2 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors cursor-pointer"
    >
      <.icon name="hero-folder" class="size-4 text-amber-500 shrink-0" />
      <span>{@folder.label}</span>
    </button>
    """
  end
end
