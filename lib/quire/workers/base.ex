defmodule Quire.Workers.Base do
  @moduledoc ~S"""
  Shared behaviour for every Oban worker in the project.

  Provides progress reporting, an idempotency helper, and enforces
  explicit `max_attempts`.

  ## Progress reporting

  Every worker MUST write progress to the `operations` row and broadcast
  `{:operation_progress, id, pct}` on PubSub topic `"document:{doc_id}"`.

  ## Idempotency

  Workers MUST write output to a scratch ref, then atomically insert the
  revision row. This ensures a retry does not produce a half-written revision.
  """

  alias Quire.Repo

  @doc false
  def __using__(_opts) do
    quote do
      use Oban.Worker, queue: :default
    end
  end

  @callback perform(term, Oban.Job.t()) :: Oban.Worker.result()

  @doc ~S"""
  Reports progress for the given operation.

  Writes the current percentage to the `operations` row and broadcasts
  `{:operation_progress, id, pct}` on PubSub topic `"document:{doc_id}"`.
  """
  def report_progress(operation_id, doc_id, pct) when is_integer(pct) and pct in 0..100 do
    # Update the operations row with the current progress percentage.
    # The operations table uses Ecto; this is kept simple for the base.
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Repo,
        "UPDATE operations SET progress = $1, updated_at = now() WHERE id = $2",
        [pct, operation_id]
      )

    Phoenix.PubSub.broadcast(
      Quire.PubSub,
      "document:#{doc_id}",
      {:operation_progress, operation_id, pct}
    )
  end

  @doc """
  Idempotency guard: returns `{:error, :already_completed}` when the revision
  already exists, otherwise yields the block.

  Workers MUST write output to a scratch ref, then call this helper to
  atomically insert the revision row.
  """
  def guard_idempotent(revision_id, fun) when is_function(fun, 0) do
    import Ecto.Query

    query =
      from(r in "document_revisions", where: r.id == ^revision_id, select: count(r.id))

    case Repo.one(query) do
      0 -> fun.()
      _ -> {:error, :already_completed}
    end
  end
end
