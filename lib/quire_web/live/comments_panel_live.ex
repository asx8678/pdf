defmodule QuireWeb.Live.CommentsPanel do
  @moduledoc """
  Comments panel LiveComponent (T-110): lists all annotations for the current
  document, grouped by page, with reply threads, resolved/unresolved status,
  and filters by author / kind / date / status.

  Renders as the `:comments` panel in the left rail. Owns its own state
  (filters, expansion, reply drafts) and queries the database directly.
  Navigates the viewer via `send/2` messages to the parent LiveView.
  """
  use Phoenix.LiveComponent

  import Ecto.Query
  import QuireWeb.CoreComponents, only: [icon: 1]

  alias Quire.Repo

  # ── Kind categories for type filtering ──────────────────────────────────

  @kind_categories [
    %{
      id: :text_markup,
      label: "Text Markup",
      kinds: ~w(highlight underline strikethrough squiggly)
    },
    %{
      id: :shape,
      label: "Shape",
      kinds: ~w(line arrow double_arrow oval rectangle polygon cloud polyline)
    },
    %{id: :stamp, label: "Stamp", kinds: ~w(stamp)},
    %{id: :whiteout, label: "Whiteout", kinds: ~w(whiteout)},
    %{id: :free_text, label: "Free Text", kinds: ~w(free_text free_text_callout)},
    %{id: :ink, label: "Ink", kinds: ~w(ink)},
    %{
      id: :measurement,
      label: "Measurement",
      kinds: ~w(measure_distance measure_perimeter measure_area)
    },
    %{id: :other, label: "Other", kinds: ~w(sticky_note signature file_attachment dimension)}
  ]

  @kind_by_category Enum.flat_map(@kind_categories, &Enum.map(&1.kinds, fn k -> {k, &1.id} end))
                    |> Map.new()

  # ── Lifecycle ───────────────────────────────────────────────────────────

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Reload when the document changes
    if socket.assigns[:document_id] != assigns.document_id do
      socket =
        socket
        |> assign(:status, :loading)
        |> assign(:annotations, [])
        |> assign(:page_groups, [])
        |> assign(:authors, [])
        |> assign(:filters, default_filters())
        |> assign(:expanded_ids, MapSet.new())
        |> assign(:replies_cache, %{})
        |> assign(:reply_inputs, %{})
        |> assign(:loading_replies, MapSet.new())
        |> load_data()

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex-1 overflow-y-auto p-3 flex flex-col gap-3">
      <%= case @status do %>
        <% :loading -> %>
          <.loading_state />
        <% :error -> %>
          <.error_state retry="reload_comments" myself={@myself} />
        <% :loaded -> %>
          <.filters_bar
            filters={@filters}
            authors={@authors}
            on_filter="apply_filter"
            on_clear="clear_filters"
            myself={@myself}
          />
          <%= if @page_groups == [] do %>
            <.empty_state />
          <% else %>
            <.annotation_list
              page_groups={@page_groups}
              filters={@filters}
              expanded_ids={@expanded_ids}
              replies_cache={@replies_cache}
              loading_replies={@loading_replies}
              reply_inputs={@reply_inputs}
              authors={@authors}
              myself={@myself}
            />
          <% end %>
      <% end %>
    </div>
    """
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("apply_filter", %{"name" => name, "value" => value}, socket) do
    filters = socket.assigns.filters

    filters =
      case name do
        "author_id" -> %{filters | author_id: if(value == "", do: nil, else: value)}
        "status" -> %{filters | status: String.to_existing_atom(value)}
        "date" -> %{filters | date: String.to_existing_atom(value)}
        _ -> filters
      end

    {:noreply, assign(socket, :filters, filters)}
  end

  def handle_event("apply_filter", %{"category" => cat, "checked" => checked}, socket) do
    cat_atom = String.to_existing_atom(cat)
    %{kinds: kinds} = Enum.find(@kind_categories, &(&1.id == cat_atom))
    current = socket.assigns.filters.kinds

    updated =
      if checked do
        current -- kinds
      else
        current ++ kinds
      end

    {:noreply, assign(socket, :filters, %{socket.assigns.filters | kinds: updated})}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, assign(socket, :filters, default_filters())}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded_ids = socket.assigns.expanded_ids
    id = coerce_id(id)

    {expanded_ids, socket} =
      if MapSet.member?(expanded_ids, id) do
        {MapSet.delete(expanded_ids, id), socket}
      else
        # Load replies for this annotation
        {MapSet.put(expanded_ids, id), load_replies(socket, id)}
      end

    {:noreply, assign(socket, :expanded_ids, expanded_ids)}
  end

  def handle_event("toggle_resolved", %{"id" => id}, socket) do
    id = coerce_id(id)

    annotations = socket.assigns.annotations
    annotation = Enum.find(annotations, &(&1.id == id))

    if annotation do
      flags = annotation.flags || %{}
      new_flags = Map.put(flags, "resolved", !Map.get(flags, "resolved", false))

      Repo.update_all(
        from(a in "annotations", where: a.id == ^id),
        set: [flags: new_flags]
      )

      # Update local state
      annotations =
        Enum.map(annotations, fn
          %{id: ^id} = a -> %{a | flags: new_flags}
          a -> a
        end)

      page_groups = group_by_page(annotations)
      {:noreply, assign(socket, annotations: annotations, page_groups: page_groups)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("post_reply", %{"annotation_id" => annotation_id, "body" => body}, socket) do
    annotation_id = coerce_id(annotation_id)

    if body && String.trim(body) != "" do
      result =
        %Quire.Documents.AnnotationReply{}
        |> Quire.Documents.AnnotationReply.changeset(%{
          annotation_id: annotation_id,
          user_id: socket.assigns.current_user_id,
          body: String.trim(body)
        })
        |> Repo.insert()

      case result do
        {:ok, reply} ->
          reply = %{
            id: reply.id,
            annotation_id: reply.annotation_id,
            user_id: reply.user_id,
            body: reply.body,
            inserted_at: reply.inserted_at
          }

          replies_cache =
            Map.update(socket.assigns.replies_cache, annotation_id, [reply], fn existing ->
              existing ++ [reply]
            end)

          reply_inputs = Map.put(socket.assigns.reply_inputs, annotation_id, "")

          update_reply_count(annotation_id)

          {:noreply,
           socket
           |> assign(:replies_cache, replies_cache)
           |> assign(:reply_inputs, reply_inputs)}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_reply_input", %{"annotation_id" => id, "value" => value}, socket) do
    id = coerce_id(id)
    reply_inputs = Map.put(socket.assigns.reply_inputs, id, value)
    {:noreply, assign(socket, :reply_inputs, reply_inputs)}
  end

  def handle_event("reload_comments", _params, socket) do
    {:noreply, socket |> assign(:status, :loading) |> load_data()}
  end

  # ── Export / Import events ──────────────────────────────────────────────

  def handle_event("export_fdf", _params, socket) do
    doc_id = socket.assigns.document_id

    case Quire.Export.FDF.generate(doc_id) do
      {:ok, content} ->
        send(self(), {:download, "annotations.fdf", content, "application/vnd.adobe.fdf"})
    end

    {:noreply, socket}
  end

  def handle_event("export_xfdf", _params, socket) do
    doc_id = socket.assigns.document_id

    case Quire.Export.XFDF.generate(doc_id) do
      {:ok, content} ->
        send(self(), {:download, "annotations.xfdf", content, "application/vnd.adobe.xfdf"})
    end

    {:noreply, socket}
  end

  def handle_event("export_csv", _params, socket) do
    doc_id = socket.assigns.document_id

    case Quire.Export.CSV.generate(doc_id) do
      {:ok, content} ->
        send(self(), {:download, "annotations.csv", content, "text/csv"})
    end

    {:noreply, socket}
  end

  def handle_event("export_summary_pdf", _params, socket) do
    doc_id = socket.assigns.document_id

    case Quire.Export.SummaryPdf.generate(doc_id) do
      {:ok, content} ->
        send(self(), {:download, "annotation-summary.pdf", content, "application/pdf"})

      {:error, reason} ->
        send(self(), {:export_error, "Summary PDF export failed: #{inspect(reason)}"})
    end

    {:noreply, socket}
  end

  def handle_event("import_xfdf", %{"file" => file}, socket) do
    doc_id = socket.assigns.document_id

    # Accept both Plug.Upload (from form upload) and raw string (from JS hook)
    case import_xml(file) do
      {:ok, xml} ->
        case Quire.Export.XFDF.import(xml, doc_id) do
          {:ok, count} ->
            send(self(), {:import_complete, count})
            {:noreply, socket |> assign(:status, :loading) |> load_data()}

          {:error, reason} ->
            send(self(), {:export_error, "XFDF import failed: #{inspect(reason)}"})
            {:noreply, socket}
        end

      {:error, reason} ->
        send(self(), {:export_error, "File read error: #{inspect(reason)}"})
        {:noreply, socket}
    end
  end

  def handle_event("import_xfdf_trigger", _params, socket) do
    # Push an event to trigger hidden file input click via JS
    {:noreply, push_event(socket, "trigger_file_input", %{})}
  end

  def handle_event("navigate_to_annotation", %{"id" => id}, socket) do
    id = coerce_id(id)
    annotation = Enum.find(socket.assigns.annotations, &(&1.id == id))

    if annotation do
      send(self(), {:navigate_to_annotation, annotation.page_index, annotation.rect})
    end

    {:noreply, socket}
  end

  defp import_xml(%Plug.Upload{} = upload) do
    File.read(upload.path)
  end

  defp import_xml(content) when is_binary(content), do: {:ok, content}
  defp import_xml(_), do: {:error, :invalid_input}

  # ── Data loading ────────────────────────────────────────────────────────

  defp load_data(socket) do
    doc_id = socket.assigns.document_id

    if is_nil(doc_id) do
      assign(socket, status: :loaded, annotations: [], page_groups: [])
    else
      try do
        annotations = query_annotations(doc_id)
        authors = collect_authors(annotations)
        page_groups = group_by_page(annotations)

        socket
        |> assign(:status, :loaded)
        |> assign(:annotations, annotations)
        |> assign(:page_groups, page_groups)
        |> assign(:authors, authors)
      rescue
        _ ->
          assign(socket, :status, :error)
      end
    end
  end

  defp query_annotations(doc_id) do
    Repo.all(
      from a in "annotations",
        where: a.document_id == ^doc_id,
        order_by: [asc: a.page_index, asc: a.inserted_at],
        select: %{
          id: a.id,
          document_id: a.document_id,
          page_index: a.page_index,
          kind: a.kind,
          rect: a.rect,
          contents: a.contents,
          author: a.author,
          color: a.color,
          opacity: a.opacity,
          flags: a.flags,
          replies_count: a.replies_count,
          inserted_at: a.inserted_at
        }
    )
    |> Enum.map(fn a ->
      %{a | flags: a.flags || %{}}
    end)
  end

  defp collect_authors(annotations) do
    annotations
    |> Enum.map(& &1.author)
    |> Enum.filter(& &1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name -> %{id: name, label: name} end)
  end

  defp group_by_page(annotations) do
    annotations
    |> Enum.group_by(& &1.page_index)
    |> Enum.sort_by(fn {page, _} -> page end)
    |> Enum.map(fn {page, anns} -> %{page: page, annotations: anns} end)
  end

  defp load_replies(socket, annotation_id) do
    if Map.has_key?(socket.assigns.replies_cache, annotation_id) do
      socket
    else
      loading_replies = MapSet.put(socket.assigns.loading_replies, annotation_id)
      socket = assign(socket, :loading_replies, loading_replies)

      replies = query_replies(annotation_id)
      replies_cache = Map.put(socket.assigns.replies_cache, annotation_id, replies)
      loading_replies = MapSet.delete(socket.assigns.loading_replies, annotation_id)

      socket
      |> assign(:replies_cache, replies_cache)
      |> assign(:loading_replies, loading_replies)
    end
  end

  defp query_replies(annotation_id) do
    Repo.all(
      from r in {"annotation_replies", Quire.Documents.AnnotationReply},
        where: r.annotation_id == ^annotation_id,
        order_by: [asc: r.inserted_at],
        select: %{
          id: r.id,
          annotation_id: r.annotation_id,
          user_id: r.user_id,
          body: r.body,
          inserted_at: r.inserted_at
        }
    )
    |> enrich_reply_authors()
  end

  defp enrich_reply_authors(replies) do
    user_ids = Enum.map(replies, & &1.user_id) |> Enum.uniq()

    if user_ids == [] do
      replies
    else
      users =
        Repo.all(
          from u in Quire.Accounts.User,
            where: u.id in ^user_ids,
            select: %{id: u.id, email: u.email}
        )
        |> Map.new(fn u -> {u.id, u.email} end)

      Enum.map(replies, fn r ->
        Map.put(r, :author_email, Map.get(users, r.user_id, "Unknown"))
      end)
    end
  end

  defp update_reply_count(annotation_id) do
    count =
      Repo.aggregate(
        from(r in {"annotation_replies", Quire.Documents.AnnotationReply},
          where: r.annotation_id == ^annotation_id
        ),
        :count,
        :id
      )

    Repo.update_all(
      from(a in "annotations", where: a.id == ^annotation_id),
      set: [replies_count: count]
    )
  end

  # ── Filters ─────────────────────────────────────────────────────────────

  defp default_filters do
    %{
      author_id: nil,
      kinds: [],
      date: :all,
      status: :all
    }
  end

  defp apply_annotations_filters(annotations, filters) do
    annotations
    |> filter_by_author(filters.author_id)
    |> filter_by_kinds(filters.kinds)
    |> filter_by_status(filters.status)
    |> filter_by_date(filters.date)
  end

  defp filter_by_author(annotations, nil), do: annotations

  defp filter_by_author(annotations, author_id) do
    Enum.filter(annotations, &(&1.author == author_id))
  end

  defp filter_by_kinds(annotations, []), do: annotations

  defp filter_by_kinds(annotations, categories) do
    excluded_kinds =
      Enum.flat_map(categories, fn cat ->
        case Enum.find(@kind_categories, &(&1.id == cat)) do
          %{kinds: kinds} -> kinds
          nil -> []
        end
      end)

    Enum.filter(annotations, fn a -> a.kind not in excluded_kinds end)
  end

  defp filter_by_status(annotations, :all), do: annotations

  defp filter_by_status(annotations, :open) do
    Enum.filter(annotations, fn a -> not Map.get(a.flags || %{}, "resolved", false) end)
  end

  defp filter_by_status(annotations, :resolved) do
    Enum.filter(annotations, fn a -> Map.get(a.flags || %{}, "resolved", false) end)
  end

  defp filter_by_date(annotations, :all), do: annotations

  defp filter_by_date(annotations, period) do
    cutoff = date_cutoff(period)

    Enum.filter(annotations, fn a ->
      case a.inserted_at do
        nil -> false
        dt -> DateTime.compare(dt, cutoff) != :lt
      end
    end)
  end

  defp date_cutoff(:today) do
    {:ok, naive} = NaiveDateTime.new(Date.utc_today(), ~T[00:00:00])
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp date_cutoff(:this_week) do
    start_of_week = Date.beginning_of_week(Date.utc_today())
    {:ok, naive} = NaiveDateTime.new(start_of_week, ~T[00:00:00])
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp date_cutoff(:this_month) do
    today = Date.utc_today()
    {:ok, naive} = NaiveDateTime.new(%{today | day: 1}, ~T[00:00:00])
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp date_cutoff(:older) do
    today = Date.utc_today()
    {:ok, naive} = NaiveDateTime.new(%{today | day: 1}, ~T[00:00:00])
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp coerce_id(nil), do: nil
  defp coerce_id(id) when is_binary(id), do: id
  defp coerce_id(id), do: to_string(id)

  defp kind_label(kind) do
    kind
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp kind_color(kind) do
    case @kind_by_category[kind] do
      :text_markup -> "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/40 dark:text-yellow-300"
      :shape -> "bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300"
      :stamp -> "bg-purple-100 text-purple-700 dark:bg-purple-900/40 dark:text-purple-300"
      :whiteout -> "bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300"
      :free_text -> "bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-300"
      :ink -> "bg-pink-100 text-pink-700 dark:bg-pink-900/40 dark:text-pink-300"
      :measurement -> "bg-orange-100 text-orange-700 dark:bg-orange-900/40 dark:text-orange-300"
      :other -> "bg-cyan-100 text-cyan-700 dark:bg-cyan-900/40 dark:text-cyan-300"
      nil -> "bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300"
    end
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(dt) when is_struct(dt, DateTime) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%b %d, %H:%M")
  end

  defp content_preview(nil), do: ""

  defp content_preview(contents) when byte_size(contents) > 80 do
    String.slice(contents, 0, 80) <> "\u2026"
  end

  defp content_preview(contents), do: contents

  # ── Sub-components ──────────────────────────────────────────────────────

  attr :rest, :global

  defp loading_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-16 gap-3">
      <div class="size-6 border-2 border-accent border-t-transparent rounded-full animate-spin"></div>
      <p class="text-xs text-gray-400 dark:text-gray-500">Loading annotations\u2026</p>
    </div>
    """
  end

  attr :retry, :string, required: true
  attr :myself, :any, required: true

  defp error_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-16 gap-3">
      <.icon name="hero-exclamation-triangle" class="size-8 text-red-400 dark:text-red-500" />
      <p class="text-sm text-gray-500 dark:text-gray-400">Failed to load annotations</p>
      <button
        type="button"
        phx-click={@retry}
        phx-target={@myself}
        class="px-3 py-1.5 text-xs font-medium bg-accent text-white rounded-lg hover:bg-accent/90 transition-colors cursor-pointer"
      >
        Retry
      </button>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-16 gap-2">
      <.icon name="hero-chat-bubble-left-right" class="size-8 text-gray-300 dark:text-gray-600" />
      <p class="text-sm text-gray-400 dark:text-gray-500">No annotations on this document</p>
    </div>
    """
  end

  attr :filters, :map, required: true
  attr :authors, :list, default: []
  attr :on_filter, :string, default: "apply_filter"
  attr :on_clear, :string, default: "clear_filters"
  attr :myself, :any, required: true

  defp filters_bar(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 border-b border-chrome-border dark:border-gray-600 pb-3">
      <!-- Export / Import toolbar -->
      <div class="flex items-center justify-between gap-1">
        <h3 class="text-xs font-medium text-gray-600 dark:text-gray-400 uppercase tracking-wider">
          Comments
        </h3>
        <div class="flex items-center gap-1">
          <button
            type="button"
            phx-click="export_fdf"
            phx-target={@myself}
            class="text-[10px] px-1.5 py-0.5 rounded bg-chrome-white dark:bg-gray-700 border border-chrome-border dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors cursor-pointer"
            title="Export FDF"
          >
            FDF
          </button>
          <button
            type="button"
            phx-click="export_xfdf"
            phx-target={@myself}
            class="text-[10px] px-1.5 py-0.5 rounded bg-chrome-white dark:bg-gray-700 border border-chrome-border dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors cursor-pointer"
            title="Export XFDF"
          >
            XFDF
          </button>
          <button
            type="button"
            phx-click="export_csv"
            phx-target={@myself}
            class="text-[10px] px-1.5 py-0.5 rounded bg-chrome-white dark:bg-gray-700 border border-chrome-border dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors cursor-pointer"
            title="Export CSV"
          >
            CSV
          </button>
          <button
            type="button"
            phx-click="export_summary_pdf"
            phx-target={@myself}
            class="text-[10px] px-1.5 py-0.5 rounded bg-chrome-white dark:bg-gray-700 border border-chrome-border dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors cursor-pointer"
            title="Export summary PDF"
          >
            PDF
          </button>
          <button
            type="button"
            phx-click="import_xfdf_trigger"
            phx-target={@myself}
            class="text-[10px] px-1.5 py-0.5 rounded bg-accent text-white hover:bg-accent/90 transition-colors cursor-pointer"
            title="Import XFDF"
          >
            Import
          </button>
        </div>
      </div>

      <!-- Hidden file input for import -->
      <input
        id="xfdf-import-input"
        type="file"
        accept=".xfdf"
        phx-hook="ImportFile"
        class="hidden"
      />

      <div class="flex items-center justify-end -mt-1">
        <button
          type="button"
          phx-click={@on_clear}
          phx-target={@myself}
          class="text-[11px] text-accent hover:underline cursor-pointer"
        >
          Clear filters
        </button>
      </div>

      <!-- Author filter -->
      <div class="flex flex-col gap-1">
        <label class="text-[11px] text-gray-500 dark:text-gray-400">Author</label>
        <select
          phx-change={@on_filter}
          phx-target={@myself}
          phx-value-name="author_id"
          class="text-xs border border-chrome-border dark:border-gray-600 rounded px-2 py-1 bg-chrome-white dark:bg-gray-800 text-gray-700 dark:text-gray-200"
        >
          <option value="">All authors</option>
          <option :for={a <- @authors} value={a.id} selected={@filters.author_id == a.id}>
            {a.label}
          </option>
        </select>
      </div>

      <!-- Type filter (kind categories) -->
      <div class="flex flex-col gap-1">
        <label class="text-[11px] text-gray-500 dark:text-gray-400">Hide type</label>
        <div class="flex flex-wrap gap-2">
          <label
            :for={cat <- @kind_categories}
            class="flex items-center gap-1 text-[11px] text-gray-600 dark:text-gray-300 cursor-pointer"
          >
            <input
              type="checkbox"
              checked={cat.id in @filters.kinds}
              phx-click={@on_filter}
              phx-target={@myself}
              phx-value-category={cat.id}
              class="rounded border-gray-300 size-3"
            /> {cat.label}
          </label>
        </div>
      </div>

      <!-- Status filter -->
      <div class="flex items-center gap-3 text-xs">
        <label class="flex items-center gap-1 cursor-pointer">
          <input
            type="radio"
            name="status"
            checked={@filters.status == :all}
            phx-click={@on_filter}
            phx-target={@myself}
            phx-value-name="status"
            phx-value-value="all"
            class="accent-accent"
          /> All
        </label>
        <label class="flex items-center gap-1 cursor-pointer">
          <input
            type="radio"
            name="status"
            checked={@filters.status == :open}
            phx-click={@on_filter}
            phx-target={@myself}
            phx-value-name="status"
            phx-value-value="open"
            class="accent-accent"
          /> Open
        </label>
        <label class="flex items-center gap-1 cursor-pointer">
          <input
            type="radio"
            name="status"
            checked={@filters.status == :resolved}
            phx-click={@on_filter}
            phx-target={@myself}
            phx-value-name="status"
            phx-value-value="resolved"
            class="accent-accent"
          /> Resolved
        </label>
      </div>

      <!-- Date filter -->
      <div class="flex flex-col gap-1">
        <label class="text-[11px] text-gray-500 dark:text-gray-400">Date</label>
        <select
          phx-change={@on_filter}
          phx-target={@myself}
          phx-value-name="date"
          class="text-xs border border-chrome-border dark:border-gray-600 rounded px-2 py-1 bg-chrome-white dark:bg-gray-800 text-gray-700 dark:text-gray-200"
        >
          <option value="all" selected={@filters.date == :all}>All time</option>
          <option value="today" selected={@filters.date == :today}>Today</option>
          <option value="this_week" selected={@filters.date == :this_week}>This week</option>
          <option value="this_month" selected={@filters.date == :this_month}>This month</option>
          <option value="older" selected={@filters.date == :older}>Older</option>
        </select>
      </div>
    </div>
    """
  end

  attr :page_groups, :list, required: true
  attr :filters, :map, required: true
  attr :expanded_ids, :map, required: true
  attr :replies_cache, :map, default: %{}
  attr :loading_replies, :map, default: MapSet.new()
  attr :reply_inputs, :map, default: %{}
  attr :authors, :list, default: []
  attr :myself, :any, required: true

  defp annotation_list(assigns) do
    ~H"""
    <div class="flex flex-col gap-4" role="listbox" aria-label="Annotations by page">
      <div :for={group <- @page_groups} class="flex flex-col gap-1">
        <div class="sticky top-0 z-10 bg-chrome-white/90 dark:bg-gray-800/90 backdrop-blur text-[11px] font-medium text-gray-400 dark:text-gray-500 uppercase tracking-wider px-1 py-1">
          Page {group.page + 1}
        </div>

        <div
          :for={annotation <- apply_annotations_filters(group.annotations, @filters)}
          class="flex flex-col"
        >
          <.annotation_card
            annotation={annotation}
            expanded={MapSet.member?(@expanded_ids, annotation.id)}
            replies={Map.get(@replies_cache, annotation.id, [])}
            loading_replies={MapSet.member?(@loading_replies, annotation.id)}
            reply_body={Map.get(@reply_inputs, annotation.id, "")}
            myself={@myself}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :annotation, :map, required: true
  attr :expanded, :boolean, default: false
  attr :replies, :list, default: []
  attr :loading_replies, :boolean, default: false
  attr :reply_body, :string, default: ""
  attr :myself, :any, required: true

  defp annotation_card(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border transition-colors",
      if(@annotation.flags["resolved"],
        do: "border-green-200 dark:border-green-800 bg-green-50/40 dark:bg-green-900/10",
        else: "border-chrome-border dark:border-gray-600 bg-chrome-white dark:bg-gray-800"
      )
    ]}>
      <!-- Annotation header (always visible) -->
      <div
        class="flex items-start gap-2 p-2.5 cursor-pointer rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
        phx-click="toggle_expand"
        phx-target={@myself}
        phx-value-id={@annotation.id}
        tabindex="0"
        role="option"
        aria-expanded={@expanded}
      >
        <!-- Color dot -->
        <span
          :if={@annotation.color}
          class="mt-1 size-2.5 shrink-0 rounded-full"
          style={"background-color: #{@annotation.color}"}
        />

        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-1.5 flex-wrap">
            <span class={[
              "text-[10px] font-medium px-1.5 py-0.5 rounded",
              kind_color(@annotation.kind)
            ]}>
              {kind_label(@annotation.kind)}
            </span>
            <span
              :if={@annotation.flags["resolved"]}
              class="text-[10px] text-green-600 dark:text-green-400"
            >
              <span class="inline-flex items-center gap-0.5">
                <.icon name="hero-check-circle" class="size-3" /> Resolved
              </span>
            </span>
          </div>

          <p class="text-xs text-gray-700 dark:text-gray-200 mt-1 leading-relaxed line-clamp-2">
            {content_preview(@annotation.contents)}
          </p>

          <div class="flex items-center gap-2 text-[10px] text-gray-400 dark:text-gray-500 mt-1">
            <span>{@annotation.author || "Unknown"}</span>
            <span>·</span>
            <span>{format_datetime(@annotation.inserted_at)}</span>
            <span :if={(@annotation.replies_count || 0) > 0} class="flex items-center gap-0.5">
              · <span>{@annotation.replies_count} replies</span>
            </span>
          </div>
        </div>

        <!-- Expand/collapse chevron -->
        <.icon
          name={if @expanded, do: "hero-chevron-up", else: "hero-chevron-down"}
          class="size-4 text-gray-400 shrink-0 mt-0.5"
        />
      </div>

      <!-- Expanded section: replies + reply input -->
      <div
        :if={@expanded}
        class="border-t border-chrome-border dark:border-gray-600 px-2.5 py-2 space-y-2"
      >
        <!-- Navigate to annotation button -->
        <button
          type="button"
          phx-click="navigate_to_annotation"
          phx-target={@myself}
          phx-value-id={@annotation.id}
          class="w-full flex items-center gap-1.5 px-2 py-1 text-[11px] text-accent hover:bg-accent/5 rounded transition-colors cursor-pointer"
        >
          <.icon name="hero-arrow-right-circle" class="size-3.5" /> Scroll to annotation
        </button>

        <!-- Resolved toggle -->
        <button
          type="button"
          phx-click="toggle_resolved"
          phx-target={@myself}
          phx-value-id={@annotation.id}
          class={[
            "w-full flex items-center gap-1.5 px-2 py-1 text-[11px] rounded transition-colors cursor-pointer",
            if(@annotation.flags["resolved"],
              do:
                "text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700",
              else: "text-green-600 dark:text-green-400 hover:bg-green-50 dark:hover:bg-green-900/20"
            )
          ]}
        >
          <.icon
            name={
              if @annotation.flags["resolved"], do: "hero-arrow-uturn-left", else: "hero-check-circle"
            }
            class="size-3.5"
          />
          {if @annotation.flags["resolved"], do: "Mark unresolved", else: "Mark resolved"}
        </button>

        <!-- Replies -->
        <div class="space-y-1.5">
          <div :if={@loading_replies} class="flex items-center gap-1.5 text-[11px] text-gray-400 py-1">
            <div class="size-3 border-2 border-accent border-t-transparent rounded-full animate-spin">
            </div>
            Loading replies\u2026
          </div>

          <div
            :for={reply <- @replies}
            class="pl-2 border-l-2 border-gray-200 dark:border-gray-600 py-1"
          >
            <p class="text-[11px] text-gray-600 dark:text-gray-300 leading-relaxed">
              {reply.body}
            </p>
            <div class="flex items-center gap-1.5 text-[10px] text-gray-400 dark:text-gray-500 mt-0.5">
              <span>{reply.author_email || "Unknown"}</span>
              <span>·</span>
              <span>{format_datetime(reply.inserted_at)}</span>
            </div>
          </div>

          <div :if={@replies == [] && !@loading_replies} class="text-[11px] text-gray-400 py-1">
            No replies yet
          </div>
        </div>

        <!-- Reply input -->
        <div class="flex items-start gap-1.5 pt-1">
          <input
            type="text"
            value={@reply_body}
            phx-change="update_reply_input"
            phx-target={@myself}
            phx-value-annotation-id={@annotation.id}
            placeholder="Write a reply\u2026"
            class="flex-1 text-xs border border-chrome-border dark:border-gray-600 rounded px-2 py-1.5 bg-chrome-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 placeholder-gray-400 focus:outline-none focus:ring-1 focus:ring-accent"
          />
          <button
            type="button"
            phx-click="post_reply"
            phx-target={@myself}
            phx-value-annotation-id={@annotation.id}
            phx-value-body={@reply_body}
            disabled={@reply_body == ""}
            class={[
              "px-2.5 py-1.5 text-xs font-medium rounded-lg transition-colors",
              if(@reply_body == "",
                do: "bg-gray-200 text-gray-400 cursor-not-allowed dark:bg-gray-700",
                else: "bg-accent text-white hover:bg-accent/90 cursor-pointer"
              )
            ]}
          >
            Reply
          </button>
        </div>
      </div>
    </div>
    """
  end
end
