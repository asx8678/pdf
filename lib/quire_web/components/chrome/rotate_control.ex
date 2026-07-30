defmodule QuireWeb.Chrome.RotateControl do
  @moduledoc """
  Rotate control (T-054): non-destructive view rotation in 90° increments,
  shown in the status bar with a tooltip for CW/CCW/Reset actions.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :rotation, :integer, default: 0
  attr :id, :string, default: "rotate-control"

  def rotate_control(assigns) do
    ~H"""
    <div id={@id} class="relative group">
      <button
        type="button"
        phx-click="rotate_cw"
        class="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
        aria-label="Rotate clockwise"
      >
        <.icon name="hero-arrow-uturn-right" class="size-3.5" />
      </button>

      <div class="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 hidden group-hover:flex flex-col gap-1 bg-gray-800 dark:bg-gray-200 text-white dark:text-gray-800 text-xs rounded-lg px-3 py-2 shadow-lg whitespace-nowrap z-50">
        <div class="flex items-center gap-2">
          <span>Rotation: {@rotation}°</span>
          <button type="button" phx-click="reset_rotation" class="text-accent hover:underline">Reset</button>
        </div>
        <button type="button" phx-click="rotate_ccw" class="text-left hover:text-accent">Rotate 90° CCW</button>
      </div>
    </div>
    """
  end
end
