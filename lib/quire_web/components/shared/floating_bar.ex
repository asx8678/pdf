defmodule QuireWeb.Shared.FloatingBar do
  @moduledoc """
  Floating toolbar (plan3.md §8.3): a small horizontal chrome bar
  absolutely positioned above content, used for contextual controls
  such as the text-selection toolbar. Callers position it via `class`.
  """
  use Phoenix.Component

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def floating_bar(assigns) do
    ~H"""
    <div class={[
      "absolute z-40 flex items-center gap-1 px-2 py-1 bg-chrome-white dark:bg-gray-800 border border-chrome-border dark:border-gray-600 rounded-lg shadow-md",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
