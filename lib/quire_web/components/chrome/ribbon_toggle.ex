defmodule QuireWeb.Chrome.RibbonToggle do
  @moduledoc """
  Ribbon toggle button (plan3.md §8.3). Mirrors `ribbon_button/1` but
  expresses an on/off state via `aria-pressed`; when pressed the button
  takes a stronger accent tint and a 1px accent ring.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :pressed, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :tooltip, :string, default: nil
  attr :rest, :global, include: ~w(phx-click phx-value-*)

  def ribbon_toggle(assigns) do
    ~H"""
    <button
      type="button"
      aria-pressed={to_string(@pressed)}
      disabled={@disabled}
      aria-label={@tooltip || @label}
      title={@tooltip}
      class={[
        "flex flex-col items-center justify-center gap-1 min-w-[64px] px-2 py-1.5 rounded-lg text-xs transition-colors",
        if(@pressed,
          do: "bg-accent/15 text-accent ring-1 ring-accent/30",
          else: "text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700"
        ),
        if(@disabled, do: "opacity-38 cursor-not-allowed", else: "cursor-pointer")
      ]}
      {@rest}
    >
      <.icon name={@icon} class="size-6" />
      <span class="text-[11px] leading-tight text-center">{@label}</span>
    </button>
    """
  end
end
