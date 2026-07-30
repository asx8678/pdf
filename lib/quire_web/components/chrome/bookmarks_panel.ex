defmodule QuireWeb.Chrome.BookmarksPanel do
  @moduledoc """
  Bookmarks panel (plan3.md §8.1): the left panel's document outline —
  a scrollable, hierarchical list of bookmarks kept in sync with the
  viewer's current page. Each item is a button that fires
  `navigate_page`; the bookmark whose page matches the current page is
  accent-highlighted. Child bookmarks indent 16px per depth level.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  # [%{title: "...", page: 1, children: [%{...}]}]
  attr :bookmarks, :list, default: []
  attr :current_page, :integer, default: 1
  attr :id, :string, default: "bookmarks-panel"

  def bookmarks_panel(assigns) do
    ~H"""
    <div id={@id} class="flex-1 overflow-y-auto p-3">
      <div class="flex items-center justify-between mb-3">
        <button
          type="button"
          phx-click="add_bookmark"
          aria-label="Add bookmark"
          class="flex items-center gap-1 text-xs text-accent hover:underline transition-colors cursor-pointer"
        >
          <.icon name="hero-plus" class="size-3.5" />
          <span>Add bookmark</span>
        </button>
      </div>

      <div :if={@bookmarks == []} class="py-12 text-center">
        <.icon name="hero-bookmark" class="size-8 text-gray-300 dark:text-gray-600 mx-auto mb-2" />
        <p class="text-xs text-gray-400 dark:text-gray-500">No bookmarks</p>
        <button
          type="button"
          phx-click="add_bookmark"
          class="mt-3 text-xs text-accent hover:underline cursor-pointer"
        >
          Add a bookmark
        </button>
      </div>

      <.bookmark_item :for={bm <- @bookmarks} bookmark={bm} current_page={@current_page} depth={0} />
    </div>
    """
  end

  attr :bookmark, :map, required: true
  attr :current_page, :integer, default: 1
  attr :depth, :integer, default: 0

  defp bookmark_item(assigns) do
    ~H"""
    <div style={"padding-left: #{@depth * 16}px"}>
      <button
        type="button"
        phx-click="navigate_page"
        phx-value-page={@bookmark.page}
        class={[
          "w-full flex items-center gap-2 px-2 py-1.5 rounded text-sm text-left transition-colors cursor-pointer",
          if(@bookmark.page == @current_page,
            do: "bg-accent/10 text-accent",
            else: "text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700"
          )
        ]}
      >
        <.icon name="hero-bookmark" class="size-3.5 shrink-0 text-gray-400" />
        <span class="truncate">{@bookmark.title}</span>
        <span class="text-[10px] text-gray-400 ml-auto shrink-0">{@bookmark.page}</span>
      </button>
      <.bookmark_item
        :for={child <- @bookmark[:children] || []}
        bookmark={child}
        current_page={@current_page}
        depth={@depth + 1}
      />
    </div>
    """
  end
end
