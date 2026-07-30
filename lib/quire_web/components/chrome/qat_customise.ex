defmodule QuireWeb.Chrome.QatCustomise do
  @moduledoc """
  Quick Access Toolbar customise dropdown (plan3.md §8.2).

  Renders a chevron trigger button that toggles a menu of checkbox items,
  one per available QAT action. The parent LiveView owns the state: it
  passes `items` (from `user_settings.qat_items`) and handles the
  `"toggle-qat-item"` event with `phx-value-id`.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :items, :list,
    default: [
      %{"id" => "undo", "label" => "Undo", "enabled" => true},
      %{"id" => "redo", "label" => "Redo", "enabled" => true},
      %{"id" => "open", "label" => "Open", "enabled" => true},
      %{"id" => "save", "label" => "Save", "enabled" => true},
      %{"id" => "print", "label" => "Print", "enabled" => true},
      %{"id" => "email", "label" => "Email", "enabled" => true},
      %{"id" => "new", "label" => "New", "enabled" => true}
    ]

  attr :open, :boolean, default: false

  def qat_customise(assigns) do
    ~H"""
    <div class="relative">
      <button
        type="button"
        aria-label="Customise Quick Access Toolbar"
        aria-expanded={to_string(@open)}
        phx-click={JS.toggle(to: "#qat-menu")}
        class="p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
      >
        <.icon name="hero-chevron-down" class="size-4 text-gray-500 dark:text-gray-400" />
      </button>

      <div
        id="qat-menu"
        class={[
          "absolute top-full left-0 mt-1 w-56 bg-chrome-white dark:bg-gray-800",
          "border border-chrome-border dark:border-gray-600 rounded-lg shadow-lg",
          "py-1 z-50",
          if(@open, do: "", else: "hidden")
        ]}
        role="menu"
        aria-label="Quick Access Toolbar items"
      >
        <div class="px-3 py-2 text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
          Customise Quick Access Toolbar
        </div>

        <div class="border-t border-chrome-border dark:border-gray-600" />

        <%= for item <- @items do %>
          <label
            role="menuitemcheckbox"
            aria-checked={to_string(item["enabled"])}
            class="flex items-center gap-3 px-3 py-2 hover:bg-gray-50 dark:hover:bg-gray-700 cursor-pointer transition-colors"
          >
            <input
              type="checkbox"
              checked={item["enabled"]}
              phx-click="toggle-qat-item"
              phx-value-id={item["id"]}
              aria-label={"Show " <> (item["label"] || "")}
              class="size-4 rounded border-gray-300 text-accent focus:ring-accent dark:border-gray-500"
            />
            <span class="text-sm text-gray-700 dark:text-gray-200">
              {item["label"]}
            </span>
          </label>
        <% end %>
      </div>
    </div>
    """
  end
end
