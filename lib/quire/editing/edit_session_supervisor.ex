defmodule Quire.Editing.EditSessionSupervisor do
  @moduledoc """
  A `DynamicSupervisor` that manages `EditSession` processes (§7.4).

  Each session is started on demand via `start_session/2` and registered
  in the `EditSessionRegistry` keyed by `{document_id, user_id}`.
  """

  use DynamicSupervisor

  @doc false
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts an `EditSession` for the given `document_id` and `user_id`.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_session(String.t(), String.t()) :: DynamicSupervisor.on_start_child()
  def start_session(document_id, user_id) do
    child_spec = {Quire.Editing.EditSession, document_id: document_id, user_id: user_id}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
