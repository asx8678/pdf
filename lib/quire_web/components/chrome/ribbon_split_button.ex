defmodule QuireWeb.Chrome.RibbonSplitButton do
  @moduledoc """
  Ribbon split button (plan3.md §8.3): a main action plus a dropdown
  arrow trigger, separated by a chrome-border rule. The main action
  carries the icon and label; the arrow opens the companion menu.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :tooltip, :string, default: nil
  attr :rest, :global, include: ~w(phx-click phx-value-*)

  def ribbon_split_button(assigns) do
    ~H"""
    <div class="relative flex">
      <button
        type="button"
        disabled={@disabled}
        aria-label={@tooltip || @label}
        title={@tooltip}
        class={[
          "flex flex-col items-center justify-center gap-1 min-w-[52px] px-2 py-1.5 rounded-l-lg text-xs transition-colors",
          if(@active,
            do: "bg-accent/10 text-accent",
            else: "text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700"
          ),
          if(@disabled, do: "opacity-38 cursor-not-allowed", else: "cursor-pointer")
        ]}
        {@rest}
      >
        <.icon name={@icon} class="size-6" />
        <span class="text-[11px] leading-tight text-center">{@label}</span>
      </button>
      <button
        type="button"
        disabled={@disabled}
        aria-label={"#{@label} more options"}
        class={[
          "px-1 rounded-r-lg border-l border-chrome-border transition-colors",
          if(@disabled,
            do: "opacity-38 cursor-not-allowed",
            else: "hover:bg-gray-100 dark:hover:bg-gray-700 cursor-pointer"
          )
        ]}
      >
        <.icon name="hero-chevron-down" class="size-3 text-gray-500 dark:text-gray-400" />
      </button>
    </div>
    """
  end
end
