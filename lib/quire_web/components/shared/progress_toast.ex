defmodule QuireWeb.Shared.ProgressToast do
  @moduledoc """
  Dismissable progress notification (plan3.md §8.3): fixed to the
  bottom-right corner with a status glyph — spinner while running,
  check on success, exclamation on error — a message, and a progress
  bar that turns red on error.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :message, :string, required: true
  attr :progress, :integer, default: 0
  attr :status, :string, default: "running"
  attr :on_dismiss, :any, default: nil

  def progress_toast(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed bottom-4 right-4 z-50 w-80 bg-chrome-white dark:bg-gray-800 border border-chrome-border dark:border-gray-600 rounded-lg shadow-lg p-4"
      role="alert"
    >
      <div class="flex items-start justify-between gap-2">
        <div class="flex items-center gap-2 min-w-0">
          <div
            :if={@status == "running"}
            class="size-4 border-2 border-accent border-t-transparent rounded-full animate-spin"
          />
          <.icon
            :if={@status == "success"}
            name="hero-check-circle"
            class="size-5 text-green-500 shrink-0"
          />
          <.icon
            :if={@status == "error"}
            name="hero-exclamation-circle"
            class="size-5 text-red-500 shrink-0"
          />
          <span class="text-sm text-gray-700 dark:text-gray-200 truncate">{@message}</span>
        </div>
        <button
          :if={@on_dismiss}
          type="button"
          phx-click={@on_dismiss}
          aria-label="Dismiss"
          class="p-0.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 shrink-0"
        >
          <.icon name="hero-x-mark" class="size-4 text-gray-400" />
        </button>
      </div>
      <div class="mt-2 w-full h-1.5 bg-gray-100 dark:bg-gray-700 rounded-full overflow-hidden">
        <div
          class={[
            "h-full rounded-full transition-all duration-300",
            if(@status == "error", do: "bg-red-500", else: "bg-accent")
          ]}
          style={"width: #{@progress}%"}
        />
      </div>
    </div>
    """
  end
end
