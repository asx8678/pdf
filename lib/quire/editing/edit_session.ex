defmodule Quire.Editing.EditSession do
  @moduledoc """
  One GenServer per open document, holding the undo/redo journal (§7.4).

  ## State

    %{document_id: ..., user_id: ..., base_revision_id: ...,
      journal: [], redo_stack: [], dirty?: false,
      subscribers: MapSet.new(), hibernate_timer: nil, terminate_timer: nil}

  ## Lifecycle

  * Hibernate after 5 minutes idle (`:hibernate` message).
  * Terminate after 30 minutes idle, persisting the journal.

  Registration in the `EditSessionRegistry` happens in `init/1`.
  """

  use GenServer

  # ── Client API ──────────────────────────────────────────────────────────

  @doc """
  Starts an `EditSession` under the configured (or default) registry.
  Accepted options:

    * `:document_id` — **required**, UUID
    * `:user_id` — **required**, UUID
    * `:base_revision_id` — optional, UUID of the last persisted revision
    * `:registry_name` — defaults to `Quire.Editing.EditSessionRegistry`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, [])
  end

  @doc """
  Applies an operation: validates, prepends to the journal, clears the
  redo stack, marks the session dirty, and resets the idle timer.
  """
  @spec apply(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def apply(session, op) do
    GenServer.call(session, {:apply, op})
  end

  @doc """
  Undoes the most recent operation in the journal.
  Returns `{:ok, undone_op}` or `{:error, :empty}`.
  """
  @spec undo(GenServer.server()) :: {:ok, map()} | {:error, :empty}
  def undo(session) do
    GenServer.call(session, {:undo})
  end

  @doc """
  Redoes the most recently undone operation from the redo stack.
  Returns `{:ok, redone_op}` or `{:error, :empty}`.
  """
  @spec redo(GenServer.server()) :: {:ok, map()} | {:error, :empty}
  def redo(session) do
    GenServer.call(session, {:redo})
  end

  @doc """
  Returns the current session state (for inspection / debugging).
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(session) do
    GenServer.call(session, {:get_state})
  end

  @doc """
  Resets the idle timers (hibernate + terminate countdowns).
  """
  @spec touch(GenServer.server()) :: :ok
  def touch(session) do
    GenServer.call(session, {:touch})
  end

  @doc """
  Returns `true` if the session has unpersisted operations (dirty).
  """
  @spec is_dirty?(GenServer.server()) :: boolean()
  def is_dirty?(session) do
    GenServer.call(session, {:is_dirty?})
  end

  @doc """
  Flushes pending client ops to an intermediate revision.

  Stores `pdf_bytes`, creates a new `document_revisions` row and
  `document_pages` rows, updates the document's `current_revision_id`,
  clears `dirty?`, and journals the flush in the undo stack.

  Returns `{:ok, %{revision_id: rev_id}}` or `{:error, reason}`.
  """
  @spec flush(GenServer.server(), binary(), String.t()) :: {:ok, map()} | {:error, term()}
  def flush(session, pdf_bytes, label \\ "Auto-save before server op") do
    GenServer.call(session, {:flush, pdf_bytes, label})
  end

  @doc """
  Registers the calling process as a subscriber for session broadcasts.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(session) do
    GenServer.call(session, {:subscribe})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  def init(opts) do
    document_id = Keyword.fetch!(opts, :document_id)
    user_id = Keyword.fetch!(opts, :user_id)
    registry_name = Keyword.get(opts, :registry_name, Quire.Editing.EditSessionRegistry)

    # Register this session in the global registry
    _ = Registry.register(registry_name, {document_id, user_id}, %{})

    state = %{
      document_id: document_id,
      user_id: user_id,
      base_revision_id: Keyword.get(opts, :base_revision_id),
      journal: [],
      redo_stack: [],
      dirty?: false,
      subscribers: MapSet.new(),
      hibernate_timer: nil,
      terminate_timer: nil
    }

    {state, _timers} = schedule_timers(state)

    {:ok, state, {:continue, :maybe_rehydrate}}
  end

  @impl true
  def handle_continue(:maybe_rehydrate, state) do
    # TODO: Rehydrate journal from edit_operations on next startup.
    # This will query recent non-undone operations for this
    # document_id and prepopulate the journal.
    {:noreply, state}
  end

  @impl true
  def handle_call({:apply, op}, _from, state) when is_map(op) do
    kind = Map.get(op, :kind) || op["kind"]
    target = Map.get(op, :target) || op["target"]
    raw_data = Map.get(op, :data) || op["data"] || op

    # Preserve coalescing-relevant fields in data
    data = if target, do: Map.put(raw_data, :target, target), else: raw_data

    op_struct = %Quire.Editing.Operation{
      kind: kind,
      data: data,
      inverse: compute_inverse(kind, op, state),
      metadata: %{applied_by: self(), applied_at: DateTime.utc_now()},
      timestamp: System.monotonic_time()
    }

    {journal, redo_stack} =
      case state.journal do
        [last | rest] ->
          if coalesce?(last, op_struct) do
            {[op_struct | rest], state.redo_stack}
          else
            {[op_struct | state.journal], []}
          end

        _ ->
          {[op_struct | state.journal], []}
      end

    new_state = %{state | journal: journal, redo_stack: redo_stack, dirty?: true}
    {reply_state, _timers} = schedule_timers(new_state)
    {:reply, {:ok, op}, reply_state}
  end

  @impl true
  def handle_call({:apply, _op}, _from, state) do
    {:reply, {:error, :invalid_op}, state}
  end

  @impl true
  def handle_call({:undo}, _from, state) do
    case state.journal do
      [] ->
        {:reply, {:error, :empty}, state}

      [head | rest] when is_struct(head, Quire.Editing.Operation) ->
        new_state = %{state | journal: rest, redo_stack: [head | state.redo_stack]}
        {reply_state, _timers} = schedule_timers(new_state)
        {:reply, {:ok, head.inverse}, reply_state}

      [head | rest] ->
        # Legacy: raw maps without inverse — just move to redo_stack
        new_state = %{state | journal: rest, redo_stack: [head | state.redo_stack]}
        {reply_state, _timers} = schedule_timers(new_state)
        {:reply, {:ok, head}, reply_state}
    end
  end

  @impl true
  def handle_call({:redo}, _from, state) do
    case state.redo_stack do
      [] ->
        {:reply, {:error, :empty}, state}

      [head | rest] when is_struct(head, Quire.Editing.Operation) ->
        # Re-apply the original operation — reconstruct the user-facing map
        new_state = %{state | journal: [head | state.journal], redo_stack: rest}
        {reply_state, _timers} = schedule_timers(new_state)
        {:reply, {:ok, %{kind: head.kind, data: head.data}}, reply_state}

      [head | rest] ->
        new_state = %{state | journal: [head | state.journal], redo_stack: rest}
        {reply_state, _timers} = schedule_timers(new_state)
        {:reply, {:ok, head}, reply_state}
    end
  end

  @impl true
  def handle_call({:get_state}, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:touch}, _from, state) do
    {reply_state, _timers} = schedule_timers(state)
    {:reply, :ok, reply_state}
  end

  @impl true
  def handle_call({:is_dirty?}, _from, state) do
    {:reply, state.dirty?, state}
  end

  @impl true
  def handle_call({:flush, pdf_bytes, label}, _from, state) do
    case do_flush(pdf_bytes, label, state) do
      {:ok, rev_id} ->
        # Journal the flush so undo can restore the prior revision.
        flush_op = %Quire.Editing.Operation{
          kind: "doc.flush",
          data: %{revision_id: rev_id, label: label},
          inverse: {:restore_revision, state.base_revision_id},
          metadata: %{applied_by: self(), applied_at: DateTime.utc_now()},
          timestamp: System.monotonic_time()
        }

        new_state = %{
          state
          | base_revision_id: rev_id,
            dirty?: false,
            journal: [flush_op | state.journal],
            redo_stack: []
        }

        {reply_state, _timers} = schedule_timers(new_state)
        {:reply, {:ok, %{revision_id: rev_id}}, reply_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:subscribe}, {pid, _}, state) do
    new_state = %{state | subscribers: MapSet.put(state.subscribers, pid)}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:hibernate, state) do
    {:noreply, state, :hibernate}
  end

  @impl true
  def handle_info(:terminate, state) do
    # TODO: Persist journal to edit_operations before stopping
    {:stop, :normal, state}
  end

  # ── Inverse computation ────────────────────────────────────────────────

  defp compute_inverse(kind, op, state) do
    case Quire.Editing.Operation.module_for_kind(kind) do
      {:ok, mod} ->
        case mod.invert(op, %{
               document_id: state.document_id,
               user_id: state.user_id,
               base_revision_id: state.base_revision_id
             }) do
          {:ok, inverse} -> inverse
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ── Coalescing ────────────────────────────────────────────────────────────

  @doc false
  def coalesce?(op1, op2) do
    {kind1, target1, ts1} = coalesce_data(op1)
    {kind2, target2, ts2} = coalesce_data(op2)

    coalescable_kind?(kind1) && kind1 == kind2 && target1 == target2 &&
      abs(ts2 - ts1) < 800_000
  end

  defp coalescable_kind?(kind), do: kind in ~w(text.style annot.update)

  defp coalesce_data(%{__struct__: Quire.Editing.Operation} = op) do
    {op.kind, op.data[:target] || op.data["target"], op.timestamp}
  end

  defp coalesce_data(op) when is_map(op) do
    kind = Map.get(op, :kind) || op["kind"]
    target = Map.get(op, :target) || op["target"]
    ts = Map.get(op, :timestamp, 0)
    {kind, target, ts}
  end

  # ── Flush (intermediate revision) ─────────────────────────────────────────

  defp do_flush(pdf_bytes, label, state) do
    with {:ok, ref} <-
           Quire.Storage.put(pdf_bytes, name: label, content_type: "application/pdf"),
         {:ok, doc} <- fetch_document(state.document_id, state.user_id) do
      # Query page metrics
      {page_count, page_geometries} = query_page_metrics(ref)

      # `:utc_datetime` columns reject microsecond precision
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Build revision source map pointing to the stored bytes
      ref_map = %{
        "storage_ref" => %{
          "adapter" => to_string(ref.adapter),
          "key" => ref.key,
          "name" => ref.name,
          "content_type" => ref.content_type,
          "byte_size" => ref.byte_size
        },
        "filename" => label,
        "flush_of" => state.base_revision_id
      }

      # Insert the new revision
      {:ok, rev} =
        Quire.Repo.insert(%Quire.Documents.Revision{
          document_id: state.document_id,
          label: label,
          source: ref_map
        })

      # Link document → this revision becomes the current one
      {:ok, _doc} =
        doc
        |> Ecto.Changeset.change(%{
          current_revision_id: rev.id,
          page_count: page_count,
          updated_at: now
        })
        |> Quire.Repo.update()

      # Insert document_pages for the new revision
      if page_geometries != [] do
        insert_page_rows(rev.id, page_geometries)
      end

      {:ok, rev.id}
    end
  end

  defp fetch_document(document_id, user_id) do
    doc = Quire.Repo.get(Quire.Documents.Document, document_id)

    cond do
      is_nil(doc) -> {:error, :not_found}
      doc.user_id != user_id -> {:error, :forbidden}
      true -> {:ok, doc}
    end
  end

  defp query_page_metrics(ref) do
    count =
      case Quire.Render.page_count(ref) do
        {:ok, n} -> n
        _ -> 0
      end

    geometries =
      case Quire.Render.page_geometry(ref) do
        {:ok, geoms} -> geoms
        _ -> []
      end

    {count, geometries}
  end

  defp insert_page_rows(revision_id, geometries) do
    # `:utc_datetime` columns reject microsecond precision; Page.width/height
    # are `:float` while page_geometry reports truncated integers.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      geometries
      |> Enum.with_index()
      |> Enum.map(fn {geom, idx} ->
        %{
          revision_id: revision_id,
          page_index: idx,
          width: geom.width * 1.0,
          height: geom.height * 1.0,
          inserted_at: now,
          updated_at: now
        }
      end)

    Quire.Repo.insert_all(Quire.Documents.Page, rows)
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  @hibernate_after 5 * 60 * 1000
  @terminate_after 30 * 60 * 1000

  defp schedule_timers(state) do
    # Cancel any existing timers
    if ref = state.hibernate_timer, do: Process.cancel_timer(ref)
    if ref = state.terminate_timer, do: Process.cancel_timer(ref)

    hibernate_ref = Process.send_after(self(), :hibernate, @hibernate_after)
    terminate_ref = Process.send_after(self(), :terminate, @terminate_after)

    {%{state | hibernate_timer: hibernate_ref, terminate_timer: terminate_ref},
     {hibernate_ref, terminate_ref}}
  end
end
