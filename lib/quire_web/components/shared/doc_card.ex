defmodule QuireWeb.Shared.DocCard do
  @moduledoc """
  Recent-document card (plan3.md §8.3): a thumbnail (or document-icon
  placeholder over the canvas tint) beside the file name, date, and
  optional size, linking back into the document.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :thumbnail_url, :string, default: nil
  attr :name, :string, required: true
  attr :date, :string, default: nil
  attr :size, :string, default: nil
  attr :href, :string, default: nil
  attr :class, :string, default: nil

  def doc_card(assigns) do
    ~H"""
    <a
      :if={@href}
      href={@href}
      class={[
        "flex gap-3 p-3 rounded-lg bg-chrome-white dark:bg-gray-800 border border-chrome-border dark:border-gray-600",
        "hover:shadow-sm hover:border-gray-300 dark:hover:border-gray-500 transition-all",
        @class
      ]}
    >
      <div class="w-12 h-16 bg-canvas dark:bg-gray-700 rounded flex items-center justify-center shrink-0 border border-chrome-border dark:border-gray-600">
        <.icon :if={!@thumbnail_url} name="hero-document" class="size-6 text-gray-400" />
        <img
          :if={@thumbnail_url}
          src={@thumbnail_url}
          alt={@name}
          class="w-full h-full object-cover rounded"
        />
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-medium text-gray-900 dark:text-gray-100 truncate">{@name}</p>
        <p class="text-xs text-gray-500 dark:text-gray-400 mt-1">
          {@date}<span :if={@size}> · {@size}</span>
        </p>
      </div>
    </a>
    """
  end
end
