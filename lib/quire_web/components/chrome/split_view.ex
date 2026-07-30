defmodule QuireWeb.Chrome.SplitView do
  @moduledoc """
  Split view toggle (T-053): switches between single-page and side-by-side
  split view with synchronised scroll.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :split, :boolean, default: false
  attr :id, :string, default: "split-view-control"

  def split_view(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_split_view"
      class={[
        "p-1 rounded transition-colors",
        if(@split,
          do: "bg-accent/10 text-accent",
          else: "hover:bg-gray-100 dark:hover:bg-gray-700"
        )
      ]}
      aria-label={if @split, do: "Close split view", else: "Split view"}
      aria-pressed={@split}
    >
      <.icon name="hero-rectangle-group" class="size-3.5" />
    </button>
    """
  end
end
