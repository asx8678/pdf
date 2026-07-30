defmodule QuireWeb.Shared.Modal do
  @moduledoc """
  Overlay dialog (plan3.md §8.3): a centred chrome card over a dimmed
  backdrop, with a header row holding the title and a close button.
  Both the backdrop and the close button fire `on_close`. Renders
  nothing unless `open` is true.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :open, :boolean, default: false
  attr :title, :string, default: nil
  attr :on_close, :any, default: nil
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      :if={@open}
      class="fixed inset-0 z-50 flex items-center justify-center"
      role="dialog"
      aria-modal="true"
      aria-label={@title}
    >
      <div class="fixed inset-0 bg-black/50" phx-click={@on_close} />
      <div class="relative bg-chrome-white dark:bg-gray-800 rounded-xl shadow-2xl max-w-lg w-full mx-4 max-h-[85vh] overflow-y-auto border border-chrome-border dark:border-gray-600">
        <div class="flex items-center justify-between px-6 py-4 border-b border-chrome-border dark:border-gray-600">
          <h2 class="text-lg font-medium text-gray-900 dark:text-gray-100">{@title}</h2>
          <button
            type="button"
            aria-label="Close"
            phx-click={@on_close}
            class="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
          >
            <.icon name="hero-x-mark" class="size-5 text-gray-500" />
          </button>
        </div>
        <div class="p-6">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end
end
