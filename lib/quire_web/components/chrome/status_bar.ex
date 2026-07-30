defmodule QuireWeb.Chrome.StatusBar do
  @moduledoc """
  Status bar (plan3.md §8.1): the bottom strip of the workspace shell.
  Operation progress sits on the left (hidden unless an operation is
  running); page navigation `‹ n / total ›` and the zoom control sit
  on the right.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]
  import QuireWeb.Chrome.ZoomControl, only: [zoom_control: 1]

  attr :page, :integer, default: 1
  attr :total_pages, :integer, default: 1
  attr :zoom, :integer, default: 100
  attr :progress, :float, default: nil
  attr :progress_label, :string, default: nil
  attr :on_prev_page, :any, default: nil
  attr :on_next_page, :any, default: nil
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
        <div
          class="flex items-center gap-1 pr-3 border-r border-chrome-border dark:border-gray-600"
          role="navigation"
          aria-label="Page navigation"
        >
          <.page_button
            direction="prev"
            disabled={@page <= 1}
            on_click={@on_prev_page}
          />
          <span class="tabular-nums">{@page} / {@total_pages}</span>
          <.page_button
            direction="next"
            disabled={@page >= @total_pages}
            on_click={@on_next_page}
          />
        </div>

        <.zoom_control zoom={@zoom} />
      </div>
    </div>
    """
  end

  attr :direction, :string, values: ["prev", "next"], required: true
  attr :disabled, :boolean, default: false
  attr :on_click, :any, default: nil

  defp page_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@on_click}
      disabled={@disabled}
      aria-label={if @direction == "prev", do: "Previous page", else: "Next page"}
      class={[
        "p-0.5 rounded transition-colors",
        if(@disabled,
          do: "opacity-38 cursor-not-allowed",
          else: "hover:bg-gray-100 dark:hover:bg-gray-700 cursor-pointer"
        )
      ]}
    >
      <.icon
        name={if @direction == "prev", do: "hero-chevron-left", else: "hero-chevron-right"}
        class="size-3.5"
      />
    </button>
    """
  end
end
