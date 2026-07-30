defmodule QuireWeb.Shared.ColorPicker do
  @moduledoc """
  Preset colour swatch grid (plan3.md §8.3): a six-column radio group
  of swatches. The selected swatch gets an accent ring and a slight
  scale; the special "transparent" swatch renders a checkerboard via a
  CSS gradient. Each selection fires `on_select` with a `color` param.
  """
  use Phoenix.Component

  @colors [
    "#FF0000",
    "#FF6600",
    "#FFCC00",
    "#00CC00",
    "#0066FF",
    "#6600FF",
    "#CC00FF",
    "#000000",
    "#666666",
    "#CCCCCC",
    "#FFFFFF",
    "transparent"
  ]

  attr :colors, :list, default: @colors
  attr :selected, :string, default: nil
  attr :on_select, :any, default: nil
  attr :class, :string, default: nil

  def color_picker(assigns) do
    ~H"""
    <div class={["grid grid-cols-6 gap-1", @class]} role="radiogroup" aria-label="Color picker">
      <button
        :for={color <- @colors}
        type="button"
        role="radio"
        aria-checked={to_string(color == @selected)}
        aria-label={color}
        phx-click={@on_select}
        phx-value-color={color}
        style={if color != "transparent", do: "background-color: #{color}"}
        class={[
          "w-6 h-6 rounded border transition-all",
          if(color == @selected,
            do: "ring-2 ring-accent ring-offset-1 scale-110",
            else: "border-chrome-border dark:border-gray-600 hover:scale-110"
          ),
          if(color == "transparent",
            do:
              "bg-white bg-[linear-gradient(45deg,#ccc_25%,transparent_25%,transparent_75%,#ccc_75%)] bg-[length:4px_4px]"
          )
        ]}
      />
    </div>
    """
  end
end
