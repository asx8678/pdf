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
    op_with_ts = Map.put(op, :timestamp, System.monotonic_time())

    {journal, redo_stack} =
      case state.journal do
        [last | rest] ->
          if coalesce?(last, op_with_ts) do
            # Coalesce: replace last entry with the new op (latest data wins)
            {[op_with_ts | rest], state.redo_stack}
          else
            {[op_with_ts | state.journal], []}
          end

        _ ->
          {[op_with_ts | state.journal], []}
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

      [head | rest] ->
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

  # ── Coalescing ────────────────────────────────────────────────────────────

  @doc false
  def coalesce?(op1, op2) do
    kind1 = Map.get(op1, :kind) || op1["kind"]
    kind2 = Map.get(op2, :kind) || op2["kind"]
    target1 = Map.get(op1, :target) || op1["target"]
    target2 = Map.get(op2, :target) || op2["target"]

    coalescable_kind?(kind1) && kind1 == kind2 && target1 == target2 &&
      within_coalesce_window?(op1, op2)
  end

  defp coalescable_kind?(kind), do: kind in ~w(text.style annot.update)

  defp within_coalesce_window?(op1, op2) do
    ts1 = Map.get(op1, :timestamp, 0)
    ts2 = Map.get(op2, :timestamp, 0)
    abs(ts2 - ts1) < 800_000
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

    {%{state | hibernate_timer: hibernate_ref, terminate_timer: terminate_ref}, {hibernate_ref, terminate_ref}}
  end
end
