defmodule QuireWeb.Chrome.ZoomControl do
  @moduledoc """
  Zoom control (plan3.md §8.3): a minus button, a percentage `<select>`
  with preset zoom levels, and a plus button. Used in the View ribbon
  and the status bar.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :zoom, :integer, default: 100
  attr :presets, :list, default: [50, 75, 100, 125, 150, 200]
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(phx-click phx-change phx-value-*)

  def zoom_control(assigns) do
    ~H"""
    <div class={["flex items-center gap-1", @class]}>
      <button
        type="button"
        aria-label="Zoom out"
        class="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
      >
        <.icon name="hero-minus" class="size-4 text-gray-500 dark:text-gray-400" />
      </button>
      <select
        aria-label="Zoom level"
        class="w-20 text-sm text-center border border-chrome-border rounded px-1 py-0.5 bg-chrome-white text-gray-700 dark:text-gray-200 focus:outline-none focus:ring-1 focus:ring-accent"
      >
        <option :for={p <- @presets} value={p} selected={p == @zoom}>{p}%</option>
      </select>
      <button
        type="button"
        aria-label="Zoom in"
        class="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
      >
        <.icon name="hero-plus" class="size-4 text-gray-500 dark:text-gray-400" />
      </button>
    </div>
    """
  end
end
