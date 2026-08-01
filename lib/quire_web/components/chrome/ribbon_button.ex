defmodule QuireWeb.Chrome.RibbonButton do
  @moduledoc """
  Vertical ribbon button (plan3.md §8.3): a 24px icon stacked over an
  11px label, minimum 64px wide. Active state is accent-tinted;
  disabled state drops to 38% opacity. An optional dropdown chevron
  indicates a companion menu.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :has_dropdown, :boolean, default: false
  attr :tooltip, :string, default: nil
  attr :rest, :global, include: ~w(phx-click phx-value-* phx-hook id)

  def ribbon_button(assigns) do
    ~H"""
    <button
      type="button"
      disabled={@disabled}
      aria-label={@tooltip || @label}
      aria-disabled={if @disabled, do: "true", else: "false"}
      title={@tooltip}
      class={[
        "relative flex flex-col items-center justify-center gap-1 min-w-[64px] px-2 py-1.5 rounded-lg text-xs transition-colors",
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
      <.icon
        :if={@has_dropdown}
        name="hero-chevron-down"
        class="size-2.5 absolute right-1 top-1/2 -translate-y-1/2"
      />
    </button>
    """
  end
end
