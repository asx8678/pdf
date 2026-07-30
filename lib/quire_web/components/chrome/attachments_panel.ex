defmodule QuireWeb.Chrome.AttachmentsPanel do
  @moduledoc """
  Attachments panel (plan3.md §8.1): the right panel's list of files
  embedded in the document — read-only for T-049. Each row is a button
  that fires `preview_attachment` with the attachment name; add/remove
  land after pdf-0g9 (embedded-file extraction) resolves. The shell's
  side_panel renders the panel header, so this only shows a file count
  when the list is non-empty, plus an empty state otherwise.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  # [%{name: "...", description: "...", size: 12345, page: nil}]
  attr :attachments, :list, default: []
  attr :id, :string, default: "attachments-panel"

  def attachments_panel(assigns) do
    ~H"""
    <div id={@id} class="flex-1 overflow-y-auto p-3 flex flex-col gap-1">
      <div :if={@attachments != []} class="flex items-center justify-end mb-2">
        <span class="text-xs text-gray-400">{length(@attachments)} files</span>
      </div>

      <.attachment_item :for={att <- @attachments} attachment={att} />

      <div :if={@attachments == []} class="py-12 text-center">
        <.icon name="hero-paper-clip" class="size-8 text-gray-300 dark:text-gray-600 mx-auto mb-2" />
        <p class="text-xs text-gray-400 dark:text-gray-500">No attachments</p>
        <p class="text-xs text-gray-400/60 dark:text-gray-500/60 mt-1">
          Attachments appear here when a document has embedded files.
        </p>
      </div>
    </div>
    """
  end

  attr :attachment, :map, required: true

  defp attachment_item(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="preview_attachment"
      phx-value-name={@attachment.name}
      class="w-full flex items-center gap-3 px-3 py-2 rounded-lg text-sm text-left transition-colors hover:bg-gray-50 dark:hover:bg-gray-700 cursor-pointer group"
    >
      <.icon name="hero-document" class="size-4 text-gray-400 shrink-0" />
      <div class="flex-1 min-w-0">
        <div class="truncate text-gray-700 dark:text-gray-200">{@attachment.name}</div>
        <div :if={@attachment[:description]} class="text-xs text-gray-400 truncate">
          {@attachment.description}
        </div>
      </div>
      <div class="text-[10px] text-gray-400 shrink-0">{format_size(@attachment.size)}</div>
    </button>
    """
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{div(bytes, 1024)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"
end
