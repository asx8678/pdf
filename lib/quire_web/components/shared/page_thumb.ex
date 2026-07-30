defmodule QuireWeb.Shared.PageThumb do
  @moduledoc """
  Page thumbnail (plan3.md §8.3): a 3:4 mini page preview button. With
  no image it falls back to a document icon over the canvas tint. The
  active page gets an accent border; every thumb carries a page-number
  badge in the bottom-right corner.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :src, :string, default: nil
  attr :page_number, :integer, required: true
  attr :active, :boolean, default: false
  attr :on_click, :any, default: nil
  attr :class, :string, default: nil

  def page_thumb(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@on_click}
      phx-value-page={@page_number}
      aria-label={"Page #{@page_number}"}
      aria-current={if @active, do: "page"}
      class={[
        "relative w-full aspect-[3/4] rounded border-2 overflow-hidden transition-all",
        if(@active,
          do: "border-accent shadow-sm",
          else: "border-chrome-border dark:border-gray-600 hover:border-gray-400"
        ),
        @class
      ]}
    >
      <img :if={@src} src={@src} alt="" class="w-full h-full object-cover" />
      <div
        :if={!@src}
        class="w-full h-full bg-canvas dark:bg-gray-700 flex items-center justify-center"
      >
        <.icon name="hero-document" class="size-8 text-gray-300 dark:text-gray-500" />
      </div>
      <span class="absolute bottom-1 right-1 text-[10px] bg-black/60 text-white px-1 rounded">
        {@page_number}
      </span>
    </button>
    """
  end
end
