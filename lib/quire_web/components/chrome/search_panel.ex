defmodule QuireWeb.Chrome.SearchPanel do
  @moduledoc """
  Search panel (plan3.md §8.1): the right panel's full-text search —
  a debounced query input with match-case / whole-word options and a
  scrollable result list. Typing fires `search`, which the workspace
  forwards to the PdfViewerHook's find controller; results arrive back
  as `search_results` and each row is a button that fires
  `search_navigate` to jump to the match's page. The current result is
  accent-highlighted.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  # [%{page: 1, text: "...", rect: %{...}}]
  attr :query, :string, default: ""
  attr :results, :list, default: []
  attr :total_results, :integer, default: 0
  attr :current_result, :integer, default: 0
  attr :match_case, :boolean, default: false
  attr :whole_word, :boolean, default: false
  attr :searching, :boolean, default: false
  attr :id, :string, default: "search-panel"

  def search_panel(assigns) do
    ~H"""
    <div id={@id} class="flex-1 overflow-y-auto p-3 flex flex-col gap-3">
      <div class="relative">
        <input
          type="text"
          placeholder="Search document…"
          value={@query}
          phx-keydown="search"
          phx-debounce="300"
          aria-label="Search document"
          class="w-full text-sm border border-chrome-border dark:border-gray-600 rounded-lg px-3 py-2 pr-8 bg-chrome-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 placeholder-gray-400 focus:outline-none focus:ring-1 focus:ring-accent"
        />
        <.icon
          name="hero-magnifying-glass"
          class="size-4 text-gray-400 absolute right-3 top-1/2 -translate-y-1/2 pointer-events-none"
        />
      </div>

      <div class="flex items-center gap-3 text-xs text-gray-500 dark:text-gray-400">
        <label class="flex items-center gap-1.5 cursor-pointer">
          <input
            type="checkbox"
            checked={@match_case}
            phx-click="toggle_search_option"
            phx-value-option="match_case"
            class="rounded border-gray-300"
          /> Match case
        </label>
        <label class="flex items-center gap-1.5 cursor-pointer">
          <input
            type="checkbox"
            checked={@whole_word}
            phx-click="toggle_search_option"
            phx-value-option="whole_word"
            class="rounded border-gray-300"
          /> Whole word
        </label>
      </div>

      <div
        :if={@query != "" && !@searching}
        class="text-xs text-gray-400 dark:text-gray-500"
        aria-live="polite"
      >
        <%= if @total_results > 0 do %>
          {@current_result + 1} of {@total_results} results
        <% else %>
          No results
        <% end %>
      </div>

      <div :if={@searching} class="flex items-center gap-2 text-xs text-gray-400 py-4">
        <div class="size-3 border-2 border-accent border-t-transparent rounded-full animate-spin">
        </div>
        Searching…
      </div>

      <div class="flex flex-col gap-1" role="listbox" aria-label="Search results">
        <button
          :for={{result, idx} <- Enum.with_index(@results)}
          type="button"
          phx-click="search_navigate"
          phx-value-page={result.page}
          phx-value-index={idx}
          role="option"
          aria-selected={idx == @current_result}
          class={[
            "w-full text-left px-3 py-2 rounded-lg text-sm transition-colors cursor-pointer",
            if(idx == @current_result,
              do: "bg-accent/10 text-accent",
              else: "text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700"
            )
          ]}
        >
          <span class="text-xs text-gray-400 mr-2">Page {result.page}</span>
          <span class="truncate">{result.text}</span>
        </button>
      </div>

      <div :if={@query == "" && @results == []} class="py-12 text-center">
        <.icon
          name="hero-magnifying-glass"
          class="size-8 text-gray-300 dark:text-gray-600 mx-auto mb-2"
        />
        <p class="text-xs text-gray-400 dark:text-gray-500">Search through document text</p>
      </div>
    </div>
    """
  end
end
