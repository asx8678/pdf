defmodule QuireWeb.Chrome.TitleBar do
  @moduledoc """
  Application title bar chrome (plan3.md §8.2).

  Renders the brand square and quick-access toolbar on the left, the
  document title in the centre, and account plus window controls on the
  right. All buttons are placeholders — no LiveView events are wired yet.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :document_title, :string, default: nil
  attr :notifications_pending, :boolean, default: false
  attr :current_user, :map, default: nil
  attr :dirty, :boolean, default: false
  attr :on_save, :any, default: nil
  attr :on_save_as, :any, default: nil
  attr :on_email, :any, default: nil

  def title_bar(assigns) do
    ~H"""
    <div class="chrome-titlebar flex items-center justify-between px-4 bg-chrome-white dark:bg-gray-800 border-b border-chrome-border dark:border-gray-600 select-none">
      <!-- Left: brand square + QAT row -->
      <div class="flex items-center gap-1">
        <!-- 44×44 accent brand square, 8px radius -->
        <div class="w-11 h-11 bg-accent rounded-lg flex items-center justify-center shrink-0">
          <span class="text-accent-fg font-bold text-lg">Q</span>
        </div>
        <!-- 24px icon row -->
        <button
          aria-label="Undo"
          class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
          disabled
        >
          <.icon name="hero-arrow-uturn-left" class="size-6 text-gray-500" />
        </button>
        <button
          aria-label="Redo"
          class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
          disabled
        >
          <.icon name="hero-arrow-uturn-right" class="size-6 text-gray-500" />
        </button>
        <button
          aria-label="Open"
          class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
        >
          <.icon name="hero-folder-open" class="size-6 text-gray-600 dark:text-gray-300" />
        </button>
        <button
          aria-label="Save"
          phx-click={if @dirty, do: @on_save}
          disabled={!@dirty}
          class={[
            "p-1.5 rounded transition-colors",
            if(@dirty,
              do: "hover:bg-gray-100 dark:hover:bg-gray-700",
              else: "opacity-50"
            )
          ]}
        >
          <.icon name="hero-cloud-arrow-down" class="size-6 text-gray-600 dark:text-gray-300" />
        </button>
        <button
          aria-label="Print"
          class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
        >
          <.icon name="hero-printer" class="size-6 text-gray-600 dark:text-gray-300" />
        </button>
        <button
          aria-label="Email"
          phx-click={@on_email}
          class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
        >
          <.icon name="hero-envelope" class="size-6 text-gray-600 dark:text-gray-300" />
        </button>
        <div class="w-px h-6 bg-chrome-border mx-1" />
        <button
          aria-label="New document"
          class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
        >
          <.icon name="hero-plus" class="size-6 text-gray-600 dark:text-gray-300" />
        </button>
        <button
          aria-label="Customise QAT"
          class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
        >
          <.icon name="hero-chevron-down" class="size-4 text-gray-500" />
        </button>
      </div>

      <!-- Centre: document title -->
      <div class="flex items-center">
        <span class="text-[15px] font-medium text-gray-700 dark:text-gray-200 truncate max-w-xs">
          {@document_title && "#{@document_title} - Quire"}
        </span>
      </div>

      <!-- Right: account + window controls -->
      <div class="flex items-center gap-1">
        <!-- Account avatar -->
        <div class="relative">
          <button
            aria-label="Account"
            class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
          >
            <.icon name="hero-user-circle" class="size-6 text-gray-600 dark:text-gray-300" />
          </button>
          <div
            :if={@notifications_pending}
            class="absolute -top-0.5 -right-0.5 w-1.5 h-1.5 bg-accent rounded-full"
          />
        </div>
        <!-- Window controls (web: hidden, desktop: shown) -->
        <div class="hidden xl:flex items-center">
          <button
            aria-label="Minimise"
            class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
          >
            <.icon name="hero-minus" class="size-4 text-gray-500" />
          </button>
          <button
            aria-label="Maximise"
            class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
          >
            <.icon name="hero-stop" class="size-4 text-gray-500" />
          </button>
          <button
            aria-label="Close"
            class="p-1.5 rounded hover:bg-red-100 dark:hover:bg-red-900 transition-colors group"
          >
            <.icon name="hero-x-mark" class="size-4 text-gray-500 group-hover:text-red-600" />
          </button>
        </div>
      </div>
    </div>
    """
  end
end
