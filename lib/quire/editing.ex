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
  Applies an operation to the session identified by `session_pid`.
  Delegates to `EditSession.apply/2`.
  """
  @spec apply(pid(), map()) :: {:ok, map()} | {:error, term()}
  def apply(session_pid, op) do
    EditSession.apply(session_pid, op)
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
