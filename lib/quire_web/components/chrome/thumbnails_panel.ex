defmodule QuireWeb.Chrome.ThumbnailsPanel do
  @moduledoc """
  Thumbnails panel (plan3.md §8.1): the left panel's page browser — a
  scrollable column of page thumbnails kept in sync with the viewer's
  current page. Each item is a `page_thumb` button that fires
  `navigate_page`; pages whose thumbnail the `:render` queue hasn't
  produced yet show the placeholder document icon.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]
  import QuireWeb.Shared.PageThumb, only: [page_thumb: 1]

  # [%{number: 1, thumbnail: "...base64..." | nil}]
  attr :pages, :list, default: []
  attr :current_page, :integer, default: 1
  attr :id, :string, default: "thumbnails-panel"

  def thumbnails_panel(assigns) do
    ~H"""
    <div id={@id} class="flex-1 overflow-y-auto p-3 space-y-2">
      <div class="flex items-center justify-between mb-2">
        <h3 class="text-xs font-medium text-gray-600 dark:text-gray-400 uppercase tracking-wider">
          Pages
        </h3>
        <span class="text-xs text-gray-400">{length(@pages)} pages</span>
      </div>

      <.page_thumb
        :for={page <- @pages}
        src={thumbnail_src(page[:thumbnail])}
        page_number={page.number}
        active={page.number == @current_page}
        on_click="navigate_page"
      />

      <div :if={@pages == []} class="py-12 text-center">
        <.icon name="hero-photo" class="size-8 text-gray-300 dark:text-gray-600 mx-auto mb-2" />
        <p class="text-xs text-gray-400 dark:text-gray-500">No thumbnails</p>
      </div>
    </div>
    """
  end

  defp thumbnail_src(nil), do: nil
  defp thumbnail_src(base64), do: "data:image/png;base64," <> base64
end
