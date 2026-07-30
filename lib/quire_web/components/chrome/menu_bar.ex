defmodule QuireWeb.Chrome.MenuBar do
  @moduledoc """
  Application menu bar chrome (plan3.md §8.2).

  Renders the backstage hamburger and home buttons on the left, the
  eleven tool tabs (§9.1–§9.11) in the centre, and the Activate now
  call-to-action plus help and settings buttons on the right. The active
  tab shows a 6px accent dot and accent-coloured text; only the
  `on_tab_click` event is wired — all other buttons are placeholders.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  @tabs [
    %{id: "view", label: "View"},
    %{id: "create-convert", label: "Create & Convert"},
    %{id: "fill-sign", label: "Fill & Sign"},
    %{id: "edit", label: "Edit"},
    %{id: "page", label: "Page"},
    %{id: "comment", label: "Comment"},
    %{id: "secure", label: "Secure"},
    %{id: "forms", label: "Forms"},
    %{id: "esign", label: "E-Sign"},
    %{id: "ocr", label: "OCR"},
    %{id: "translate", label: "Translate"}
  ]

  attr :active_tab, :string, default: "view"
  attr :on_tab_click, :any, default: nil
  attr :on_hamburger_click, :any, default: nil
  attr :backstage_open, :boolean, default: false

  def menu_bar(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div class="chrome-menubar flex items-center px-2 bg-chrome-white border-b border-chrome-border select-none">
      <!-- Left: hamburger + home -->
      <button
        aria-label="Backstage"
        aria-expanded={@backstage_open}
        aria-controls="backstage-overlay"
        phx-click={@on_hamburger_click}
        class="p-2 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
      >
        <.icon name="hero-bars-3" class="size-5 text-gray-600 dark:text-gray-300" />
      </button>
      <button
        aria-label="Home"
        class="p-2 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
      >
        <.icon name="hero-home" class="size-5 text-gray-600 dark:text-gray-300" />
      </button>

      <!-- Tabs -->
      <div class="flex items-center h-full ml-2" role="tablist" aria-label="Document tools">
        <%= for tab <- @tabs do %>
          <button
            role="tab"
            aria-selected={to_string(tab.id == @active_tab)}
            phx-click={@on_tab_click}
            phx-value-tab={tab.id}
            class={[
              "relative flex items-center gap-1.5 h-full px-4 text-sm transition-colors",
              if(tab.id == @active_tab,
                do: "text-accent font-medium",
                else:
                  "text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 rounded"
              )
            ]}
          >
            <span
              :if={tab.id == @active_tab}
              class="absolute left-1 top-1/2 -translate-y-1/2 w-1.5 h-1.5 bg-accent rounded-full"
            />
            {tab.label}
          </button>
        <% end %>
      </div>

      <!-- Right: Activate now + help + gear -->
      <div class="flex items-center gap-1 ml-auto">
        <button class="bg-gray-900 text-white text-xs font-medium px-3 py-1.5 rounded-md hover:bg-gray-800 transition-colors whitespace-nowrap">
          Activate now
        </button>
        <button
          aria-label="Help"
          class="p-2 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
        >
          <.icon name="hero-question-mark-circle" class="size-5 text-gray-500 dark:text-gray-400" />
        </button>
        <button
          aria-label="Settings"
          class="p-2 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
        >
          <.icon name="hero-cog-6-tooth" class="size-5 text-gray-500 dark:text-gray-400" />
        </button>
      </div>
    </div>
    """
  end
end
