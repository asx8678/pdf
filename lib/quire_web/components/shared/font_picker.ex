defmodule QuireWeb.Shared.FontPicker do
  @moduledoc """
  Font family and size selects (plan3.md §8.3): a pair of compact
  selects sharing one `phx-change` event. The changed control is
  identified by its `name` (`family` or `size`) in the event params;
  family options render in their own typeface.
  """
  use Phoenix.Component

  @families ["Inter", "Arial", "Helvetica", "Times New Roman", "Courier New", "Georgia"]
  @sizes [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72]

  attr :family, :string, default: "Inter"
  attr :size, :integer, default: 12
  attr :on_change, :any, default: nil
  attr :class, :string, default: nil

  def font_picker(assigns) do
    assigns = assign(assigns, families: @families, sizes: @sizes)

    ~H"""
    <div class={["flex items-center gap-2", @class]}>
      <select
        aria-label="Font family"
        name="family"
        phx-change={@on_change}
        class="text-sm border border-chrome-border dark:border-gray-600 rounded px-2 py-1 bg-chrome-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 focus:outline-none focus:ring-1 focus:ring-accent max-w-36"
      >
        <option
          :for={f <- @families}
          value={f}
          selected={f == @family}
          style={"font-family: #{f}"}
        >
          {f}
        </option>
      </select>
      <select
        aria-label="Font size"
        name="size"
        phx-change={@on_change}
        class="w-16 text-sm border border-chrome-border dark:border-gray-600 rounded px-1 py-1 bg-chrome-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 focus:outline-none focus:ring-1 focus:ring-accent"
      >
        <option :for={s <- @sizes} value={s} selected={s == @size}>{s}</option>
      </select>
    </div>
    """
  end
end
