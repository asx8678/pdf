defmodule QuireWeb.Chrome.LayersPanel do
  @moduledoc """
  Layers panel (plan3.md §8.1, T-050): the left panel's optional
  content group (OCG) list — a scrollable list of the document's
  layers with a visibility checkbox per row. Clicking a row fires
  `toggle_layer`; hidden layers dim their name, locked layers show a
  lock and don't toggle. The real OCG wiring (pdf.js
  `getOptionalContentConfig`) lands with T-051.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  # [%{name: "...", visible: true, locked: false}]
  attr :layers, :list, default: []
  attr :id, :string, default: "layers-panel"

  def layers_panel(assigns) do
    ~H"""
    <div id={@id} class="flex-1 overflow-y-auto p-3">
      <div class="flex items-center justify-between mb-3">
        <h3 class="text-xs font-medium text-gray-600 dark:text-gray-400 uppercase tracking-wider">
          Layers
        </h3>
        <span :if={@layers != []} class="text-xs text-gray-400">{length(@layers)} layers</span>
      </div>

      <button
        :for={layer <- @layers}
        type="button"
        phx-click="toggle_layer"
        phx-value-name={layer.name}
        aria-pressed={to_string(layer.visible)}
        class="w-full flex items-center gap-2 px-2 py-1.5 rounded text-left hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors cursor-pointer"
      >
        <span class={[
          "size-4 shrink-0 rounded border flex items-center justify-center transition-colors",
          if(layer.visible,
            do: "bg-accent border-accent",
            else: "border-gray-300 dark:border-gray-500"
          )
        ]}>
          <.icon :if={layer.visible} name="hero-check" class="size-3 text-accent-fg" />
        </span>
        <span class={[
          "text-sm truncate",
          if(layer.visible,
            do: "text-gray-700 dark:text-gray-200",
            else: "text-gray-400 dark:text-gray-500"
          )
        ]}>
          {layer.name}
        </span>
        <.icon
          :if={layer.locked}
          name="hero-lock-closed"
          class="size-3 ml-auto shrink-0 text-gray-300 dark:text-gray-600"
        />
      </button>

      <div :if={@layers == []} class="py-12 text-center">
        <.icon
          name="hero-rectangle-stack"
          class="size-8 text-gray-300 dark:text-gray-600 mx-auto mb-2"
        />
        <p class="text-xs text-gray-400 dark:text-gray-500">No layers</p>
        <p class="text-xs text-gray-400/60 dark:text-gray-500/60 mt-1">
          Open a document to see its optional content groups.
        </p>
      </div>
    </div>
    """
  end
end
