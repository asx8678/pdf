defmodule Quire.Workers.RetentionWorker do
  @moduledoc """
  Periodic worker that prunes old document revisions and their storage refs.

  Runs on the `maintenance` queue at a configurable interval. The retention
  period defaults to 30 days and can be overridden via application config:

      config :quire, Quire.Workers.RetentionWorker, retention_days: 60

  ## Idempotency

  The worker is idempotent: querying for revisions older than the cutoff and
  not referenced by `current_revision_id` will only find revisions that have
  not yet been pruned. Running it twice produces the same result.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 2

  alias Quire.Repo
  alias Quire.Documents.Revision
  alias Quire.Documents.Document
  alias Quire.Storage

  import Ecto.Query

  @default_retention_days 30

  @impl Oban.Worker
  def perform(_job) do
    retention_days = Application.get_env(:quire, __MODULE__, []) |> Keyword.get(:retention_days, @default_retention_days)
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    # Find revisions older than cutoff that are NOT the current revision of any document
    old_revisions =
      Repo.all(
        from r in Revision,
          left_join: d in Document,
          on: d.current_revision_id == r.id,
          where: r.inserted_at < ^cutoff and is_nil(d.id),
          select: r
      )

    {pruned_count, reclaimed_bytes} = prune_revisions(old_revisions)

    emit_telemetry(pruned_count, reclaimed_bytes)

    if pruned_count > 0 do
      require Logger
      Logger.info("RetentionWorker: pruned #{pruned_count} revisions, reclaimed #{format_bytes(reclaimed_bytes)}")
    end

    :ok
  end

  defp prune_revisions([]), do: {0, 0}

  defp prune_revisions(revisions) do
    revision_ids = Enum.map(revisions, & &1.id)
    reclaimed_bytes = Enum.reduce(revisions, 0, &count_bytes/2)

    # Delete storage refs for each revision
    Enum.each(revisions, fn rev ->
      case Revision.storage_ref(rev) do
        nil -> :ok
        ref -> Storage.delete(ref)
      end
    end)

    # Delete the revision rows (cascades to document_pages, document_page_text)
    {count, _} = Repo.delete_all(from r in Revision, where: r.id in ^revision_ids)

    {count, reclaimed_bytes}
  end

  defp count_bytes(%Revision{} = rev, acc) do
    case rev.source do
      %{"storage_ref" => %{"byte_size" => size}} when is_integer(size) -> acc + size
      _ -> acc
    end
  end

  defp format_bytes(n) when n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 2)} MB"
  defp format_bytes(n) when n >= 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_bytes(n), do: "#{n} B"

  defp emit_telemetry(count, bytes) do
    :telemetry.execute(
      [:quire, :retention, :pruned],
      %{count: count, reclaimed_bytes: bytes},
      %{}
    )
  rescue
    _ -> :ok
  end
end
