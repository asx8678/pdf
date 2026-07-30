defmodule QuireWeb.Chrome.DocumentTabs do
  @moduledoc """
  Document tab strip (plan3.md §8.2): 40 px tall (`chrome-document-tab`
  token), one chip per open document with an unsaved-changes dot and a
  close button. The active tab is white with accent text and an accent
  bottom edge; inactive tabs are grey on the chrome background. Labels
  truncate at ~18 characters with the full title in a tooltip.

  Emits LiveView events for tab switching, closing, and drag-and-drop
  reorder. A colocated JS hook (`TabStrip`) handles HTML5 native drag
  and drop. Keyboard shortcuts (Ctrl/⌘+W, Ctrl/⌘+Tab, Ctrl/⌘+Shift+Tab)
  are handled by the workspace shell's `phx-keydown` binding (T-033).
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :documents, :list, required: true
  # [%{id: 1, title: "Contract.pdf", dirty: false, path: "/path"}]
  attr :active_id, :any, default: nil
  attr :class, :string, default: nil

  def document_tabs(assigns) do
    ~H"""
    <div
      id="document-tablist"
      class={[
        "chrome-document-tab flex items-center bg-chrome-white dark:bg-gray-800 border-b border-chrome-border dark:border-gray-600 overflow-x-auto select-none",
        @class
      ]}
      role="tablist"
      aria-label="Open documents"
      phx-hook="TabStrip"
    >
      <div
        :for={doc <- @documents}
        role="tab"
        draggable="true"
        data-tab-id={doc.id}
        aria-selected={to_string(doc.id == @active_id)}
        title={doc.title}
        phx-click="switch_tab"
        phx-value-id={doc.id}
        class={[
          "flex items-center gap-2 h-full px-3 text-sm border-b-2 transition-colors cursor-pointer shrink-0 max-w-[200px]",
          if(doc.id == @active_id,
            do: "text-accent border-b-accent bg-white dark:bg-gray-900",
            else:
              "text-gray-500 dark:text-gray-400 border-b-transparent hover:text-gray-700 dark:hover:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700"
          )
        ]}
      >
        <span class="truncate">{doc.title}</span>
        <span
          :if={doc.dirty}
          role="img"
          aria-label="Unsaved changes"
          class="size-2 shrink-0 rounded-full bg-gray-400 dark:bg-gray-500"
        />
        <button
          type="button"
          aria-label={"Close #{doc.title}"}
          phx-click="close_tab"
          phx-value-id={doc.id}
          class="p-0.5 rounded hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors shrink-0 cursor-pointer"
        >
          <.icon name="hero-x-mark" class="size-3" />
        </button>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TabStrip">
      export default {
        mounted() {
          this.el.addEventListener("dragstart", e => {
            e.target.classList.add("opacity-50");
            e.dataTransfer.effectAllowed = "move";
            e.dataTransfer.setData("text/plain", e.target.dataset.tabId);
          });
          this.el.addEventListener("dragend", e => {
            e.target.classList.remove("opacity-50");
          });
          this.el.addEventListener("dragover", e => {
            e.preventDefault();
            e.dataTransfer.dropEffect = "move";
            const tab = e.target.closest('[role="tab"]');
            if (tab) tab.classList.add("border-l-2", "border-l-accent");
          });
          this.el.addEventListener("dragleave", e => {
            const tab = e.target.closest('[role="tab"]');
            if (tab) tab.classList.remove("border-l-2", "border-l-accent");
          });
          this.el.addEventListener("drop", e => {
            e.preventDefault();
            const fromId = e.dataTransfer.getData("text/plain");
            const toTab = e.target.closest('[role="tab"]');
            if (toTab) {
              const toId = toTab.dataset.tabId;
              this.pushEvent("reorder_tabs", {from: fromId, to: toId});
            }
          });
        }
      }
    </script>
    """
  end
end
