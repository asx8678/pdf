defmodule Quire.Editing do
  @moduledoc """
  The Editing context (§7.4).

  Provides the public API for opening, applying, undoing and redoing
  document-editing operations. Each open document gets an `EditSession`
  GenServer under a `DynamicSupervisor`, registered in the
  `EditSessionRegistry` keyed by `{document_id, user_id}`.
  """

  alias Quire.Editing.EditSession
  alias Quire.Editing.EditSessionSupervisor

  @doc """
  Opens (or looks up) a session for the given document and user.

  If a session already exists in the Registry, its pid is returned.
  Otherwise a new `EditSession` is started under the supervisor.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec open_session(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def open_session(document_id, user_id) do
    key = {document_id, user_id}

    case Registry.lookup(Quire.Editing.EditSessionRegistry, key) do
      [{pid, _value} | _] ->
        {:ok, pid}

      [] ->
        EditSessionSupervisor.start_session(document_id, user_id)
    end
  end

  @doc """
  Applies a client-side operation to the session identified by `session_pid`.
  Delegates to `EditSession.apply/2`.
  """
  @spec apply(pid(), map()) :: {:ok, map()} | {:error, term()}
  def apply(session_pid, op) do
    EditSession.apply(session_pid, op)
  end

  @doc """
  Applies a server-side operation.

  Before applying, checks whether the session has unpersisted client edits.

  ## Returns

    * `{:ok, result}` — no pending client edits; the op was journaled normally.
    * `{:flush_required, pid}` — there are unpersisted client edits.
      The caller MUST flush via `flush/3` before retrying.
    * `{:error, reason}` — the op could not be applied.
  """
  @spec apply_for_server(pid(), map()) ::
          {:ok, map()} | {:flush_required, pid()} | {:error, term()}
  def apply_for_server(session_pid, op) do
    if EditSession.is_dirty?(session_pid) do
      {:flush_required, session_pid}
    else
      EditSession.apply(session_pid, Map.put(op, "applied_side", :server))
    end
  end

  @doc """
  Returns `true` if the session has unpersisted client edits (dirty).
  """
  @spec dirty?(pid()) :: boolean()
  def dirty?(session_pid) do
    EditSession.is_dirty?(session_pid)
  end

  @doc """
  Flushes pending client edits to an intermediate revision.

  Stores `pdf_bytes` as a new revision, updates the document's
  `current_revision_id`, and clears the session's dirty flag.
  Journals the flush so undo can restore the prior revision.

  Returns `{:ok, %{revision_id: id}}` or `{:error, reason}`.
  """
  @spec flush(pid(), binary(), String.t()) :: {:ok, map()} | {:error, term()}
  def flush(session_pid, pdf_bytes, label \\ "Auto-save before server op") do
    # Quick header validation — reject non-PDF bytes early.
    if binary_part(pdf_bytes, 0, 5) == <<37, 80, 68, 70, 45>> do
      EditSession.flush(session_pid, pdf_bytes, label)
    else
      {:error, :invalid_pdf}
    end
  end

  @doc """
  Undoes the last operation in the session's journal.
  Delegates to `EditSession.undo/1`.
  """
  @spec undo(pid()) :: {:ok, map()} | {:error, :empty}
  def undo(session_pid) do
    EditSession.undo(session_pid)
  end

  @doc """
  Redoes the last undone operation.
  Delegates to `EditSession.redo/1`.
  """
  @spec redo(pid()) :: {:ok, map()} | {:error, :empty}
  def redo(session_pid) do
    EditSession.redo(session_pid)
  end

  @doc """
  Closes the session for the given document and user.

  Looks up the session pid in the Registry and stops it.
  Returns `:ok` if a session existed, `{:error, :not_found}` otherwise.
  """
  @spec close_session(String.t(), String.t()) :: :ok | {:error, :not_found}
  def close_session(document_id, user_id) do
    key = {document_id, user_id}

    case Registry.lookup(Quire.Editing.EditSessionRegistry, key) do
      [{pid, _value} | _] ->
        DynamicSupervisor.terminate_child(Quire.Editing.EditSessionSupervisor, pid)
        :ok

      [] ->
        {:error, :not_found}
    end
  end
end
