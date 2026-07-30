defmodule QuireWeb.HomeLive do
  @moduledoc """
  The home screen (plan3.md §10.1): a two-column tile grid of PDF tools
  on the left, a Recent panel on the right, an empty-state drop zone,
  and floating feedback/support buttons bottom-right.

  Mounted at `/` as a standalone LiveView — it renders inside the
  scaffold `Layouts.app` (with the app title bar), not the workspace
  chrome shell. The Customize tile opens a modal to show/hide tiles;
  reordering and persistence to `user_settings` land with the file-open
  pipeline (T-044).
  """
  use QuireWeb, :live_view

  import QuireWeb.Chrome.TitleBar, only: [title_bar: 1]
  import QuireWeb.Shared.DocCard, only: [doc_card: 1]
  import QuireWeb.Shared.Modal, only: [modal: 1]

  @tiles [
    %{id: "open", icon: "hero-folder-open", title: "Open PDF", desc: "Open a PDF file"},
    %{
      id: "clipboard",
      icon: "hero-clipboard",
      title: "Clipboard to PDF",
      desc: "From clipboard content"
    },
    %{
      id: "merge",
      icon: "hero-document-plus",
      title: "Merge files",
      desc: "Combine multiple PDFs"
    },
    %{
      id: "convert",
      icon: "hero-arrow-right-on-rectangle",
      title: "Convert to PDF",
      desc: "From Word, Excel, images"
    },
    %{
      id: "toword",
      icon: "hero-document-text",
      title: "PDF to Word",
      desc: "Convert PDF to Word format"
    },
    %{
      id: "toexcel",
      icon: "hero-table-cells",
      title: "PDF to Excel",
      desc: "Convert PDF to Excel format"
    },
    %{
      id: "comment",
      icon: "hero-chat-bubble-left-right",
      title: "Add comment",
      desc: "Annotate a PDF"
    },
    %{
      id: "protect",
      icon: "hero-lock-closed",
      title: "Protect your PDF",
      desc: "Password & permissions"
    },
    %{id: "batch", icon: "hero-cog-6-tooth", title: "Batch", desc: "Chain operations on files"},
    %{
      id: "customize",
      icon: "hero-adjustments-horizontal",
      title: "Customize",
      desc: "Reorder and hide tiles"
    }
  ]

  @fab_items [
    %{icon: "hero-hand-thumb-up", label: "Feedback"},
    %{icon: "hero-chat-bubble-oval-left-ellipsis", label: "Support"}
  ]

  @sort_options [
    {"last_opened", "Last opened"},
    {"name", "Name"},
    {"size", "Size"},
    {"type", "Type"},
    {"date", "Date created"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Home - Quire")
      |> assign(:tiles, @tiles)
      |> assign(:fab_items, @fab_items)
      |> assign(:sort_options, @sort_options)
      |> assign(:show_customize, false)
      |> assign(:hidden_tiles, MapSet.new())
      |> assign(:sort_by, "last_opened")
      |> assign(:view_mode, "grid")
      |> assign(:recent_docs, [])
      |> assign(:uploading, false)
      |> assign(:open_error, nil)
      |> assign(:show_password_prompt, false)
      |> assign(:pending_bytes, nil)
      |> assign(:pending_title, nil)
      |> assign(:password_form, to_form(%{}))
      |> allow_upload(:pdf, accept: ~w(.pdf), max_entries: 1, max_file_size: 500_000_000)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.title_bar document_title="Home" />

      <div class="flex gap-6 w-full">
        <!-- Left: tile grid -->
        <div class="flex-1">
          <.empty_state :if={@recent_docs == []} />

          <div class="grid grid-cols-2 gap-4 w-fit">
            <.tile_card
              :for={tile <- visible_tiles(@tiles, @hidden_tiles)}
              tile={tile}
              on_click={
                cond do
                  tile.id == "open" -> "open_pdf"
                  tile.id == "customize" -> "open_customize"
                  true -> nil
                end
              }
            />
          </div>

          <%!-- Hidden upload form triggered by the Open PDF tile --%>
          <form id="pdf-upload-form" phx-submit="upload" class="hidden" phx-hook=".FileTrigger">
            <.live_file_input upload={@uploads.pdf} id="pdf-upload-input" accept=".pdf" />
          </form>
        </div>

        <!-- Right: Recent panel -->
        <div class="w-80 shrink-0">
          <.recent_panel
            recent_docs={@recent_docs}
            sort_by={@sort_by}
            view_mode={@view_mode}
            sort_options={@sort_options}
          />
        </div>
      </div>

      <!-- Floating action buttons -->
      <div class="fixed bottom-6 right-6 flex flex-col gap-4 z-40">
        <button
          :for={fab <- @fab_items}
          type="button"
          aria-label={fab.label}
          class="w-14 h-14 rounded-full bg-gray-900 dark:bg-gray-700 text-white shadow-lg hover:shadow-xl hover:scale-105 transition-all flex items-center justify-center"
        >
          <.icon name={fab.icon} class="size-6" />
        </button>
      </div>

      <.password_prompt_modal
        :if={@show_password_prompt}
        on_submit="submit_password"
        on_cancel="cancel_password"
        form={@password_form}
      />

      <.customize_modal
        :if={@show_customize}
        tiles={@tiles}
        hidden_tiles={@hidden_tiles}
        on_close="close_customize"
      />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".FileTrigger">
        export default {
          mounted() {
            this.handleEvent("trigger_file_picker", () => {
              // Find the live_file_input inside the hidden upload form
              const input = document.getElementById("pdf-upload-input");
              if (input) input.click();
            });
          }
        }
      </script>
    </Layouts.app>
    """
  end

  # ── Event handlers ────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_pdf", _params, socket) do
    # Push event to the .FileTrigger colocated hook, which clicks the
    # hidden live_file_input and opens the native file picker.
    {:noreply, push_event(socket, "trigger_file_picker", %{})}
  end

  def handle_event("open_customize", _params, socket) do
    {:noreply, assign(socket, :show_customize, true)}
  end

  def handle_event("close_customize", _params, socket) do
    {:noreply, assign(socket, :show_customize, false)}
  end

  def handle_event("toggle_tile", %{"id" => id}, socket) do
    hidden =
      if MapSet.member?(socket.assigns.hidden_tiles, id) do
        MapSet.delete(socket.assigns.hidden_tiles, id)
      else
        MapSet.put(socket.assigns.hidden_tiles, id)
      end

    {:noreply, assign(socket, :hidden_tiles, hidden)}
  end

  def handle_event("sort_changed", %{"sort_by" => sort_by}, socket) do
    valid = Enum.map(@sort_options, &elem(&1, 0))
    {:noreply, assign(socket, :sort_by, if(sort_by in valid, do: sort_by, else: "last_opened"))}
  end

  def handle_event("set_view_mode", %{"mode" => mode}, socket) when mode in ["grid", "list"] do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  @impl true
  def handle_event("upload", _params, socket) do
    # Consume the uploaded file and run the ingest pipeline.
    # Phoenix.LiveView calls this when the upload-submit form fires;
    # we read the file from the temp path and feed it through ingest.
    [%{meta: %{name: name}, bytes: pdf_bytes}] =
      consume_uploaded_entries(socket, :pdf, fn meta, entry ->
        %{meta: meta, bytes: File.read!(entry.path)}
      end)

    title = name

    socket =
      socket
      |> assign(:uploading, true)
      |> assign(:open_error, nil)

    case Quire.Documents.ingest(pdf_bytes, socket.assigns.current_scope, title: title) do
      {:ok, %{document: doc, document_url: _url}} ->
        socket =
          socket
          |> assign(:uploading, false)
          |> put_flash(:info, "Opening #{doc.title}")

        {:noreply, push_navigate(socket, to: ~p"/workspace/#{doc.id}")}

      {:error, :password_required} ->
        {:noreply,
         socket
         |> assign(:uploading, false)
         |> assign(:show_password_prompt, true)
         |> assign(:pending_bytes, pdf_bytes)
         |> assign(:pending_title, title)}

      {:error, :invalid_pdf} ->
        {:noreply,
         socket
         |> assign(:uploading, false)
         |> put_flash(:error, "The file is not a valid PDF")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:uploading, false)
         |> put_flash(:error, "Failed to open document: #{inspect(reason)}")}
    end
  end

  def handle_event("submit_password", _params, socket) do
    if socket.assigns.pending_bytes do
      {:noreply,
       socket
       |> assign(:show_password_prompt, false)
       |> assign(:pending_bytes, nil)
       |> assign(:pending_title, nil)
       |> put_flash(:error, "Password-protected PDF support is not yet available")}
    else
      {:noreply, assign(socket, :show_password_prompt, false)}
    end
  end

  def handle_event("cancel_password", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_password_prompt, false)
     |> assign(:pending_bytes, nil)
     |> assign(:pending_title, nil)}
  end

  def handle_event("clear_recent", _params, socket) do
    {:noreply, assign(socket, :recent_docs, [])}
  end

  # ── Components ────────────────────────────────────────────────────────────

  # The Customize tile always stays visible — hiding it would strand the
  # only way back into the customize modal.
  defp visible_tiles(tiles, hidden_tiles) do
    Enum.reject(tiles, &(&1.id != "customize" && MapSet.member?(hidden_tiles, &1.id)))
  end

  attr :tile, :map, required: true
  attr :on_click, :any, default: nil

  defp tile_card(assigns) do
    ~H"""
    <div
      phx-click={@on_click}
      class="flex flex-col items-center justify-center gap-3 w-[140px] h-[140px] p-4 rounded-xl bg-chrome-white dark:bg-gray-800 border border-chrome-border dark:border-gray-600 hover:shadow-md hover:border-gray-300 dark:hover:border-gray-500 hover:-translate-y-0.5 transition-all cursor-pointer"
    >
      <div class="w-10 h-10 bg-accent/10 rounded-xl flex items-center justify-center">
        <.icon name={@tile.icon} class="size-6 text-accent" />
      </div>
      <div class="text-center">
        <p class="text-xs font-medium text-gray-900 dark:text-gray-100 leading-tight">
          {@tile.title}
        </p>
        <p class="text-[10px] text-gray-500 dark:text-gray-400 leading-tight mt-0.5">
          {@tile.desc}
        </p>
      </div>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center gap-4 p-12 mb-6 border-2 border-dashed border-gray-300 dark:border-gray-600 rounded-xl bg-gray-50 dark:bg-gray-800/50">
      <.icon name="hero-document-arrow-up" class="size-12 text-gray-300 dark:text-gray-600" />
      <p class="text-sm text-gray-500 dark:text-gray-400 text-center">
        Drop a PDF here or choose a tool to start
      </p>
    </div>
    """
  end

  attr :recent_docs, :list, default: []
  attr :sort_by, :string, default: "last_opened"
  attr :view_mode, :string, default: "grid"
  attr :sort_options, :list, required: true

  defp recent_panel(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-3">
        <h2 class="text-sm font-medium text-gray-700 dark:text-gray-200">Recent</h2>
        <button
          type="button"
          phx-click="clear_recent"
          class="text-xs text-accent hover:underline"
        >
          Clear all
        </button>
      </div>

      <div class="flex items-center gap-2 mb-4">
        <form id="sort-form" phx-change="sort_changed">
          <select
            name="sort_by"
            aria-label="Sort by"
            class="text-xs border border-chrome-border rounded px-2 py-1 bg-chrome-white text-gray-600 dark:text-gray-300 dark:bg-gray-800 dark:border-gray-600"
          >
            <option :for={{value, label} <- @sort_options} value={value} selected={@sort_by == value}>
              {label}
            </option>
          </select>
        </form>
        <div class="flex border border-chrome-border dark:border-gray-600 rounded overflow-hidden">
          <button
            type="button"
            aria-label="Grid view"
            phx-click="set_view_mode"
            phx-value-mode="grid"
            class={["p-1", @view_mode == "grid" && "bg-gray-100 dark:bg-gray-700"]}
          >
            <.icon name="hero-squares-2x2" class="size-3.5 text-gray-500 dark:text-gray-400" />
          </button>
          <button
            type="button"
            aria-label="List view"
            phx-click="set_view_mode"
            phx-value-mode="list"
            class={["p-1", @view_mode == "list" && "bg-gray-100 dark:bg-gray-700"]}
          >
            <.icon name="hero-list-bullet" class="size-3.5 text-gray-500 dark:text-gray-400" />
          </button>
        </div>
      </div>

      <div :if={@recent_docs == []} class="text-center py-8">
        <p class="text-xs text-gray-400 dark:text-gray-500">No recent documents</p>
      </div>

      <.doc_card
        :for={doc <- @recent_docs}
        name={doc.name}
        date={doc[:date]}
        size={doc[:size]}
        href={doc[:href]}
        class="mb-2"
      />
    </div>
    """
  end

  attr :on_submit, :string, required: true
  attr :on_cancel, :string, required: true
  attr :form, :any, required: true

  defp password_prompt_modal(assigns) do
    ~H"""
    <.modal title="Password required" on_close={@on_cancel} open={true}>
      <p class="text-sm text-gray-500 dark:text-gray-400 mb-4">
        This PDF is encrypted. Enter the document password to open it.
      </p>
      <.form
        for={@form}
        id="password-form"
        phx-submit={@on_submit}
        class="space-y-4"
      >
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          placeholder="Enter document password"
          required
          autocomplete="off"
        />
        <div class="flex justify-end gap-2">
          <.button type="submit" variant="primary">Open</.button>
          <.button type="button" phx-click={@on_cancel} variant="outline">Cancel</.button>
        </div>
      </.form>
    </.modal>
    """
  end

  attr :tiles, :list, required: true
  attr :hidden_tiles, :any, required: true
  attr :on_close, :string, required: true

  defp customize_modal(assigns) do
    ~H"""
    <.modal title="Customize tiles" on_close={@on_close} open={true}>
      <p class="text-sm text-gray-500 dark:text-gray-400 mb-4">
        Show or hide tiles on the home screen
      </p>
      <div class="space-y-1">
        <div
          :for={tile <- @tiles}
          class="flex items-center gap-3 px-3 py-2 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
        >
          <.icon name="hero-grip-vertical" class="size-4 text-gray-400 cursor-grab" />
          <.icon name={tile.icon} class="size-4 text-accent" />
          <span class="text-sm text-gray-700 dark:text-gray-200 flex-1">{tile.title}</span>
          <button
            :if={tile.id != "customize"}
            type="button"
            phx-click="toggle_tile"
            phx-value-id={tile.id}
            aria-label={
              if MapSet.member?(@hidden_tiles, tile.id),
                do: "Show #{tile.title}",
                else: "Hide #{tile.title}"
            }
            class="p-1 rounded hover:bg-gray-200 dark:hover:bg-gray-600"
          >
            <.icon
              name={if MapSet.member?(@hidden_tiles, tile.id), do: "hero-eye-slash", else: "hero-eye"}
              class="size-4 text-gray-500 dark:text-gray-400"
            />
          </button>
        </div>
      </div>
    </.modal>
    """
  end
end
