defmodule QuireWeb.Chrome.PageWorkspace do
  @moduledoc """
  Page tab workspace (T-059): a full-workspace thumbnail grid that
  replaces the pdf.js viewer when the Page tab is active. Supports
  multi-select (click, shift-click, ctrl-click), zoom slider, and
  grid/single-page layout toggle.

  Renders inside `<main id="document-canvas">` when `@active_tab == "page"`.
  Click events are dispatched through the `PageWorkspace` colocated hook
  which captures modifier-key state.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]
  import QuireWeb.Shared.PageThumb, only: [page_thumb: 1]

  @doc """
  Renders the Page tab workspace with a toolbar and scrollable
  thumbnail grid.

  ## Attributes
  - `pages` — list of `%{number: integer, thumbnail: binary | nil}`
  - `current_page` — the active page number
  - `selected_pages` — list of selected page numbers
  - `page_zoom` — zoom percentage (50-200)
  - `page_layout` — `"grid"` or `"single"`
  - `total_pages` — total number of pages
  """
  attr :pages, :list, default: []
  attr :current_page, :integer, default: 1
  attr :selected_pages, :list, default: []
  attr :page_zoom, :integer, default: 100
  attr :page_layout, :string, default: "grid"
  attr :total_pages, :integer, default: 1

  def page_workspace(assigns) do
    ~H"""
    <div
      id="page-workspace"
      phx-hook=".PageWorkspace"
      class="flex flex-col h-full bg-canvas dark:bg-gray-900"
      role="region"
      aria-label="Page thumbnail workspace"
    >
      <!-- Toolbar -->
      <div class="flex items-center justify-between px-4 py-2 border-b border-chrome-border dark:border-gray-600 shrink-0">
        <div class="flex items-center gap-3">
          <span class="text-sm text-gray-600 dark:text-gray-400 font-medium">
            Pages
          </span>
          <span class="text-xs text-gray-400">({@total_pages})</span>
          <span :if={@selected_pages != []} class="text-xs text-accent font-medium">
            {length(@selected_pages)} selected
          </span>
        </div>
        <div class="flex items-center gap-3">
          <!-- Zoom slider -->
          <div class="flex items-center gap-2">
            <.icon name="hero-minus" class="size-3.5 text-gray-400" />
            <input
              type="range"
              min="50"
              max="200"
              step="10"
              value={@page_zoom}
              phx-change="page_zoom_change"
              class="w-20 h-1.5 accent-accent cursor-pointer"
              aria-label="Thumbnail zoom"
            />
            <.icon name="hero-plus" class="size-3.5 text-gray-400" />
            <span class="text-xs text-gray-500 w-8 text-right tabular-nums">{@page_zoom}%</span>
          </div>

          <!-- Layout toggle -->
          <button
            type="button"
            phx-click="toggle_page_layout"
            class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors cursor-pointer"
            aria-label={
              if @page_layout == "grid", do: "Switch to single page view", else: "Switch to grid view"
            }
          >
            <.icon
              name={if @page_layout == "grid", do: "hero-squares-2x2", else: "hero-document"}
              class="size-4 text-gray-600 dark:text-gray-300"
            />
          </button>
        </div>
      </div>

      <!-- Thumbnail grid / single page scroll area -->
      <div class="flex-1 overflow-y-auto p-4" id="page-workspace-scroll">
        <div
          id="page-workspace-grid"
          class={[
            @page_layout == "grid" && "grid gap-4",
            @page_layout == "grid" && grid_cols(@page_zoom),
            @page_layout == "single" && "flex flex-col items-center gap-4"
          ]}
        >
          <div
            :for={page <- @pages}
            id={"page-workspace-thumb-#{page.number}"}
            data-page={page.number}
            draggable="true"
            class={[
              "relative cursor-grab active:cursor-grabbing transition-all duration-150",
              @page_layout == "single" && "w-full max-w-md"
            ]}
          >
            <div class={[
              "rounded-lg overflow-hidden transition-all duration-150",
              page.number == @current_page && "ring-2 ring-accent",
              page.number in @selected_pages && "ring-2 ring-blue-500"
            ]}>
              <.page_thumb
                src={thumbnail_src(page[:thumbnail])}
                page_number={page.number}
                active={page.number == @current_page}
                class="pointer-events-none"
              />
            </div>
            <!-- Selected checkmark -->
            <div
              :if={page.number in @selected_pages}
              class="absolute top-2 right-2 w-5 h-5 bg-blue-500 rounded-full flex items-center justify-center shadow-sm"
            >
              <.icon name="hero-check" class="size-3 text-white" />
            </div>
          </div>
        </div>

        <div :if={@pages == []} class="py-16 text-center">
          <.icon name="hero-photo" class="size-10 text-gray-300 dark:text-gray-600 mx-auto mb-2" />
          <p class="text-sm text-gray-400 dark:text-gray-500">No page thumbnails</p>
        </div>
      </div>
    </div>

    <style>
      /* Drag-and-drop insertion caret (T-060) */
      .drag-caret-before,
      .drag-caret-after {
        position: relative;
      }

      .drag-caret-before::before,
      .drag-caret-after::after {
        content: "";
        position: absolute;
        top: 0;
        bottom: 0;
        width: 3px;
        background: #3b82f6;
        border-radius: 2px;
        z-index: 10;
        pointer-events: none;
      }

      .drag-caret-before::before {
        left: -6px;
      }

      .drag-caret-after::after {
        right: -6px;
      }

      /* Active drag cursor */
      .opacity-50 {
        opacity: 0.5;
      }
    </style>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".PageWorkspace">
      export default {
        mounted() {
          // Click handler for multi-select (shift/ctrl+click)
          this._onClick = (e) => {
            const wrapper = e.target.closest("[data-page]");
            if (!wrapper) return;
            const page = parseInt(wrapper.dataset.page, 10);
            this.pushEvent("page_thumb_click", {
              page: page,
              shift: e.shiftKey,
              ctrl: e.ctrlKey || e.metaKey
            });
          };
          this.el.addEventListener("click", this._onClick);

          // Drag-and-drop reorder (T-060)
          this._onDragStart = (e) => {
            const wrapper = e.target.closest("[data-page]");
            if (!wrapper) return;
            const page = wrapper.dataset.page;
            e.dataTransfer.setData("text/plain", page);
            e.dataTransfer.effectAllowed = "move";
            wrapper.classList.add("opacity-50");
            this._dragSource = wrapper;
          };

          this._onDragOver = (e) => {
            const sourcePage = this._dragSource?.dataset?.page;
            e.preventDefault();
            e.dataTransfer.dropEffect = "move";

            // Find the thumbnail under cursor
            const target = e.target.closest("[data-page]");

            // Clear old drop indicators on every thumbnail
            this.el.querySelectorAll(".drag-caret-before, .drag-caret-after").forEach((el) => {
              el.classList.remove("drag-caret-before", "drag-caret-after");
            });

            if (!target || !sourcePage || target.dataset.page === sourcePage) return;

            // Determine before/after based on cursor X relative to target
            const rect = target.getBoundingClientRect();
            const x = e.clientX - rect.left;
            const midX = rect.width / 2;
            const position = x < midX ? "before" : "after";

            target.classList.add(position === "before" ? "drag-caret-before" : "drag-caret-after");
            this._dragTarget = target;
          };

          this._onDrop = (e) => {
            e.preventDefault();
            const sourcePage = e.dataTransfer.getData("text/plain");
            const target = e.target.closest("[data-page]");
            if (!target || !sourcePage || target.dataset.page === sourcePage) return;

            const targetPage = target.dataset.page;

            // Determine position from the drop point
            const rect = target.getBoundingClientRect();
            const x = e.clientX - rect.left;
            const midX = rect.width / 2;
            const position = x < midX ? "before" : "after";

            this.pushEvent("reorder_pages", {
              source: sourcePage,
              target: targetPage,
              position: position
            });
          };

          this._onDragEnd = () => {
            this.el.querySelectorAll(".opacity-50, .drag-caret-before, .drag-caret-after").forEach((el) => {
              el.classList.remove("opacity-50", "drag-caret-before", "drag-caret-after");
            });
            this._dragSource = null;
            this._dragTarget = null;
          };

          this.el.addEventListener("dragstart", this._onDragStart);
          this.el.addEventListener("dragover", this._onDragOver);
          this.el.addEventListener("drop", this._onDrop);
          this.el.addEventListener("dragend", this._onDragEnd);
        },
        destroyed() {
          if (this._onClick) {
            this.el.removeEventListener("click", this._onClick);
          }
          this.el.removeEventListener("dragstart", this._onDragStart);
          this.el.removeEventListener("dragover", this._onDragOver);
          this.el.removeEventListener("drop", this._onDrop);
          this.el.removeEventListener("dragend", this._onDragEnd);
        }
      };
    </script>
    """
  end

  defp thumbnail_src(nil), do: nil
  defp thumbnail_src(base64), do: "data:image/png;base64," <> base64

  # Responsive grid columns based on zoom level — smaller zoom = more columns
  defp grid_cols(zoom) when zoom <= 60,
    do: "grid-cols-3 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-6 xl:grid-cols-7"

  defp grid_cols(zoom) when zoom <= 80,
    do: "grid-cols-3 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-6"

  defp grid_cols(zoom) when zoom <= 100,
    do: "grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5"

  defp grid_cols(zoom) when zoom <= 130, do: "grid-cols-2 sm:grid-cols-3 md:grid-cols-4"
  defp grid_cols(zoom) when zoom <= 170, do: "grid-cols-2 sm:grid-cols-3"
  defp grid_cols(_zoom), do: "grid-cols-1 sm:grid-cols-2"
end
