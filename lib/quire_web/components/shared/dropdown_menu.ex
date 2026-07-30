defmodule QuireWeb.Shared.DropdownMenu do
  @moduledoc """
  Pop-up dropdown menu (plan3.md §8.3): a chrome card holding menu
  items with optional leading icons, separated by divider rules. Items
  carry `role="menuitem"` and dividers `role="separator"`; disabled
  items drop to 38% opacity and refuse pointer interaction.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  # Items are maps: %{label: "...", icon: "...", action: "...", divider: false, disabled: false}
  attr :items, :list, required: true
  attr :class, :string, default: nil

  def dropdown_menu(assigns) do
    ~H"""
    <div
      class={[
        "min-w-40 bg-chrome-white dark:bg-gray-800 border border-chrome-border dark:border-gray-600 rounded-lg shadow-lg py-1 z-50",
        @class
      ]}
      role="menu"
    >
      <%= for item <- @items do %>
        <div
          :if={item[:divider]}
          class="border-t border-chrome-border dark:border-gray-600 my-1"
          role="separator"
        />
        <button
          :if={!item[:divider]}
          type="button"
          role="menuitem"
          disabled={item[:disabled]}
          phx-click={item[:action]}
          class={[
            "w-full flex items-center gap-3 px-3 py-2 text-sm text-left transition-colors",
            if(item[:disabled],
              do: "opacity-38 cursor-not-allowed",
              else:
                "hover:bg-gray-50 dark:hover:bg-gray-700 cursor-pointer text-gray-700 dark:text-gray-200"
            )
          ]}
        >
          <.icon :if={item[:icon]} name={item[:icon]} class="size-4 text-gray-400 shrink-0" />
          {item[:label]}
        </button>
      <% end %>
    </div>
    """
  end
end
