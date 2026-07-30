defmodule QuireWeb.Chrome.ShortcutsModal do
  @moduledoc """
  Keyboard shortcuts reference (plan3.md §8.5, T-033): every binding in
  the keyboard map, grouped by category, each combo rendered as a `kbd`
  chip. Opened with `?` (Shift+/) from the workspace shell and closed
  with `Esc`, the backdrop, or the header close button. Combos are shown
  with `⌘`; on Windows/Linux read it as Ctrl.
  """
  use Phoenix.Component

  import QuireWeb.Shared.Modal, only: [modal: 1]

  attr :on_close, :any, default: nil

  # Keyword list (not a map) so the categories render in this order.
  @shortcuts [
    {"File",
     [
       %{keys: "⌘O", label: "Open document"},
       %{keys: "⌘S", label: "Save"},
       %{keys: "⌘⇧S", label: "Save as"},
       %{keys: "⌘P", label: "Print"},
       %{keys: "⌘W", label: "Close document"}
     ]},
    {"Edit",
     [
       %{keys: "⌘Z", label: "Undo"},
       %{keys: "⌘⇧Z / ⌘Y", label: "Redo"},
       %{keys: "⌘A", label: "Select all"},
       %{keys: "Del", label: "Delete selection"}
     ]},
    {"Find",
     [
       %{keys: "⌘F", label: "Find"},
       %{keys: "⌘G", label: "Find next"},
       %{keys: "⌘⇧G", label: "Find previous"}
     ]},
    {"Navigation",
     [
       %{keys: "⌘Tab", label: "Next document tab"},
       %{keys: "⌘⇧Tab", label: "Previous document tab"},
       %{keys: "PgUp", label: "Previous page"},
       %{keys: "PgDn", label: "Next page"},
       %{keys: "Home", label: "First page"},
       %{keys: "End", label: "Last page"}
     ]},
    {"View",
     [
       %{keys: "⌘+", label: "Zoom in"},
       %{keys: "⌘-", label: "Zoom out"},
       %{keys: "⌘0", label: "Fit page"},
       %{keys: "⌘1", label: "Actual size"},
       %{keys: "F11", label: "Fullscreen"}
     ]},
    {"Other",
     [
       %{keys: "Esc", label: "Cancel / close modal"},
       %{keys: "?", label: "Keyboard shortcuts"},
       %{keys: "Alt+letter", label: "Ribbon tab access keys"}
     ]}
  ]

  def shortcuts_modal(assigns) do
    assigns = assign(assigns, :shortcuts, @shortcuts)

    ~H"""
    <.modal title="Keyboard shortcuts" on_close={@on_close} open={true}>
      <div class="space-y-6">
        <section :for={{category, items} <- @shortcuts} aria-label={category}>
          <h3 class="text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider mb-2">
            {category}
          </h3>
          <div class="divide-y divide-chrome-border dark:divide-gray-700">
            <div :for={item <- items} class="flex items-center justify-between gap-4 py-1.5">
              <span class="text-sm text-gray-700 dark:text-gray-200">{item.label}</span>
              <kbd class="shrink-0 px-2 py-0.5 text-xs font-mono bg-gray-100 dark:bg-gray-700 border border-chrome-border dark:border-gray-600 border-b-2 rounded text-gray-600 dark:text-gray-300">
                {item.keys}
              </kbd>
            </div>
          </div>
        </section>
      </div>
    </.modal>
    """
  end
end
