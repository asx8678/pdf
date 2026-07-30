defmodule QuireWeb.Shared.Panel do
  @moduledoc """
  Collapsible side panel (plan3.md §8.3): a chrome column with a header
  button that toggles the body open or closed. The chevron points down
  when open and up when closed; the body scrolls independently.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :title, :string, required: true
  attr :open, :boolean, default: true
  attr :on_toggle, :any, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <div class={[
      "flex flex-col bg-chrome-white dark:bg-gray-800 border-r border-chrome-border dark:border-gray-600",
      @class
    ]}>
      <button
        type="button"
        phx-click={@on_toggle}
        aria-expanded={to_string(@open)}
        class="flex items-center justify-between px-4 py-3 text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
      >
        {@title}
        <.icon
          name={if @open, do: "hero-chevron-down", else: "hero-chevron-up"}
          class="size-4 text-gray-400"
        />
      </button>
      <div :if={@open} class="flex-1 overflow-y-auto px-4 py-2">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
