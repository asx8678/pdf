defmodule QuireWeb.Chrome.PageNavPill do
  @moduledoc """
  Page navigation pill (T-057): compact prev/current/total/next control
  for the workspace status bar.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :id, :string, default: "page-nav-pill"

  def page_nav_pill(assigns) do
    ~H"""
    <div id={@id} class="flex items-center gap-1 bg-chrome-bg border border-chrome-border rounded-full px-2 py-1">
      <button
        type="button"
        phx-click="navigate_page"
        phx-value-page={@page - 1}
        disabled={@page <= 1}
        class="p-0.5 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
        aria-label="Previous page"
      >
        <.icon name="hero-chevron-left" class="size-3.5" />
      </button>

      <form phx-submit="navigate_to_page" class="flex items-center gap-1">
        <input
          type="number"
          name="page"
          value={@page}
          min="1"
          max={@total_pages}
          class="w-8 text-center text-xs border-none bg-transparent text-gray-700 dark:text-gray-200 p-0 focus:outline-none [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
          aria-label="Page number"
        />
      </form>

      <span class="text-xs text-gray-400 dark:text-gray-500">/ {@total_pages}</span>

      <button
        type="button"
        phx-click="navigate_page"
        phx-value-page={@page + 1}
        disabled={@page >= @total_pages}
        class="p-0.5 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
        aria-label="Next page"
      >
        <.icon name="hero-chevron-right" class="size-3.5" />
      </button>
    </div>
    """
  end
end
