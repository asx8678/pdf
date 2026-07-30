defmodule QuireWeb.Chrome.Rail do
  @moduledoc """
  Side rail (plan3.md §8.2): a 48 px wide (`chrome-rail` token),
  icon-only strip of 24 px glyphs. One rail flanks each side of the
  document canvas; pressing a rail button toggles the panel adjacent
  to that side. The same component renders the left rail (thumbnails,
  bookmarks) and the right rail (search, attachments) — only the items
  and the border side differ.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :items, :list, required: true
  # [%{id: :thumbnails, icon: "hero-squares-2x2", label: "Thumbnails", active: false}]
  attr :side, :string, values: ["left", "right"], default: "left"
  attr :on_item_click, :any, default: nil
  attr :class, :string, default: nil

  def rail(assigns) do
    ~H"""
    <div
      class={[
        "chrome-rail flex flex-col items-center py-2 gap-1 bg-chrome-white dark:bg-gray-800 border-chrome-border dark:border-gray-600",
        if(@side == "left", do: "border-r", else: "border-l"),
        @class
      ]}
      role="toolbar"
      aria-orientation="vertical"
      aria-label={"#{String.capitalize(@side)} rail"}
    >
      <button
        :for={item <- @items}
        type="button"
        phx-click={@on_item_click}
        phx-value-side={@side}
        phx-value-item={item[:id]}
        aria-label={item.label}
        aria-pressed={to_string(item[:active] == true)}
        title={item.label}
        class={[
          "flex items-center justify-center w-9 h-9 rounded-lg transition-colors cursor-pointer",
          if(item[:active],
            do: "bg-accent/10 text-accent",
            else:
              "text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-700 hover:text-gray-700 dark:hover:text-gray-200"
          )
        ]}
      >
        <.icon name={item.icon} class="size-6" />
      </button>
    </div>
    """
  end
end
