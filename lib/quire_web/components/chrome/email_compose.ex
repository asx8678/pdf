defmodule QuireWeb.Chrome.EmailCompose do
  @moduledoc """
  Email compose modal (plan3.md §8.2, T-198).

  A modal for composing and attaching the current document to an email.
  Shows To, CC, Subject, and Body fields with a Send button. In Phase 1
  the modal renders but Send is non-functional — actual delivery via
  Swoosh lands with the full pipeline.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]
  import QuireWeb.Shared.Modal, only: [modal: 1]

  attr :open, :boolean, default: false
  attr :document_title, :string, default: nil
  attr :on_close, :any, default: nil
  attr :on_send, :any, default: nil

  def email_compose(assigns) do
    ~H"""
    <.modal title="Send as email" open={@open} on_close={@on_close}>
      <form phx-submit={@on_send} class="space-y-4">
        <div>
          <label
            for="email-to"
            class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
          >
            To
          </label>
          <input
            id="email-to"
            type="email"
            name="to"
            required
            placeholder="recipient@example.com"
            class="w-full px-3 py-2 border border-chrome-border dark:border-gray-600 rounded-lg text-sm bg-chrome-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-accent focus:border-accent outline-none"
          />
        </div>

        <div>
          <label
            for="email-cc"
            class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
          >
            CC
          </label>
          <input
            id="email-cc"
            type="email"
            name="cc"
            placeholder="cc@example.com"
            class="w-full px-3 py-2 border border-chrome-border dark:border-gray-600 rounded-lg text-sm bg-chrome-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-accent focus:border-accent outline-none"
          />
        </div>

        <div>
          <label
            for="email-subject"
            class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
          >
            Subject
          </label>
          <input
            id="email-subject"
            type="text"
            name="subject"
            value={"#{@document_title}" <> " - shared via Quire"}
            class="w-full px-3 py-2 border border-chrome-border dark:border-gray-600 rounded-lg text-sm bg-chrome-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-accent focus:border-accent outline-none"
          />
        </div>

        <div>
          <label
            for="email-body"
            class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
          >
            Message
          </label>
          <textarea
            id="email-body"
            name="body"
            rows="4"
            placeholder="Add a message..."
            class="w-full px-3 py-2 border border-chrome-border dark:border-gray-600 rounded-lg text-sm bg-chrome-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-accent focus:border-accent outline-none resize-none"
          ></textarea>
        </div>

        <!-- Attachment indicator -->
        <div class="flex items-center gap-2 px-3 py-2 bg-gray-50 dark:bg-gray-700/50 rounded-lg text-sm text-gray-600 dark:text-gray-400">
          <.icon name="hero-paper-clip" class="size-4" />
          <span class="flex-1">{@document_title || "Untitled document"}</span>
          <span class="text-xs text-gray-400">PDF · attached</span>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <button
            type="button"
            phx-click={@on_close}
            class="px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="px-4 py-2 text-sm font-medium bg-accent text-white rounded-lg hover:bg-accent/90 transition-colors"
          >
            Send
          </button>
        </div>
      </form>
    </.modal>
    """
  end
end
