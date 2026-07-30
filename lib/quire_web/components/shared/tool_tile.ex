defmodule QuireWeb.Shared.ToolTile do
  @moduledoc """
  Home-page feature tile (plan3.md §8.3): an accent-tinted icon well
  stacked over a label and optional description, linking to the tool.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, default: nil
  attr :href, :string, default: nil
  attr :class, :string, default: nil

  def tool_tile(assigns) do
    ~H"""
    <a
      :if={@href}
      href={@href}
      class={[
        "flex flex-col items-center gap-2 p-6 rounded-xl border border-chrome-border dark:border-gray-600",
        "bg-chrome-white dark:bg-gray-800 hover:shadow-md hover:border-gray-300 dark:hover:border-gray-500 transition-all",
        @class
      ]}
    >
      <div class="w-12 h-12 bg-accent/10 rounded-xl flex items-center justify-center">
        <.icon name={@icon} class="size-6 text-accent" />
      </div>
      <span class="text-sm font-medium text-gray-900 dark:text-gray-100">{@label}</span>
      <span :if={@description} class="text-xs text-gray-500 dark:text-gray-400 text-center">
        {@description}
      </span>
    </a>
    """
  end
end
