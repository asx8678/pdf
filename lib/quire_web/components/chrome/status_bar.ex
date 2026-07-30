defmodule QuireWeb.Chrome.StatusBar do
  @moduledoc """
  Status bar (plan3.md §8.1): the bottom strip of the workspace shell.
  Operation progress sits on the left (hidden unless an operation is
  running); page navigation `‹ n / total ›` and the zoom control sit
  on the right.
  """
  use Phoenix.Component

  import QuireWeb.Chrome.PageNavPill, only: [page_nav_pill: 1]
  import QuireWeb.Chrome.ZoomControl, only: [zoom_control: 1]

  attr :page, :integer, default: 1
  attr :total_pages, :integer, default: 1
  attr :zoom, :integer, default: 100
  attr :progress, :float, default: nil
  attr :progress_label, :string, default: nil
  attr :class, :string, default: nil

  def status_bar(assigns) do
    ~H"""
    <div class={[
      "flex items-center justify-between h-8 px-4 bg-chrome-white dark:bg-gray-800 border-t border-chrome-border dark:border-gray-600 text-xs text-gray-500 dark:text-gray-400 select-none",
      @class
    ]}>
      <div class="flex items-center gap-2" aria-live="polite">
        <div :if={@progress} class="flex items-center gap-2">
          <div
            class="w-24 h-1.5 bg-gray-100 dark:bg-gray-700 rounded-full overflow-hidden"
            role="progressbar"
            aria-valuenow={round(@progress * 100)}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-label={@progress_label || "Operation progress"}
          >
            <div
              class="h-full bg-accent rounded-full transition-all duration-300"
              style={"width: #{round(@progress * 100)}%"}
            />
          </div>
          <span :if={@progress_label} class="text-gray-400 dark:text-gray-500">
            {@progress_label}
          </span>
        </div>
      </div>

      <div class="flex items-center gap-4">
        <div class="pr-3 border-r border-chrome-border dark:border-gray-600">
          <.page_nav_pill page={@page} total_pages={@total_pages} />
        </div>

        <.zoom_control zoom={@zoom} />
      </div>
    </div>
    """
  end


end
