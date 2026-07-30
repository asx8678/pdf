defmodule QuireWeb.Chrome.RibbonGroup do
  @moduledoc """
  Ribbon control group (plan3.md §8.3).

  Wraps a set of related ribbon controls and renders a 1px × 44px
  separator rule after them. The group's label sits beneath the
  controls, centred, in the ribbon's group-label style.
  """
  use Phoenix.Component

  attr :label, :string, required: true
  attr :class, :string, default: nil

  slot :inner_block, required: true

  def ribbon_group(assigns) do
    ~H"""
    <div class={["flex items-center", @class]}>
      <div class="flex flex-col items-center justify-end h-full">
        <div class="flex items-center gap-0.5 flex-1">
          {render_slot(@inner_block)}
        </div>
        <span class="text-[10px] text-gray-500 dark:text-gray-400 leading-tight select-none">
          {@label}
        </span>
      </div>
      <div class="w-px h-11 bg-chrome-border mx-2" aria-hidden="true" />
    </div>
    """
  end
end
