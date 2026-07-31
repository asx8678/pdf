defmodule Quire.Workers.AutoCreateFieldsWorker do
  @moduledoc ~S"""
  Oban worker for scanned-form field detection (T-125).

  Detection is CPU-heavy (raster analysis per page), so it runs here — on the
  `:ocr` queue, serialised — while the LiveView stays responsive.  The job
  only *detects*; committing is a separate, fast step the user triggers from
  the preview (accept/discard), per the T-125 done-when.

  ## Job args

      %{
        "doc_id"       => doc_id,          # required
        "revision_id"  => revision_id,     # required
        "operation_id" => op_id            # required, for progress reporting
      }

  ## Output

  On success the job broadcasts `{:auto_create_detections, op_id,
  %{total: n, fields: [...]}}` on PubSub topic `"document:{doc_id}"` and
  reports 100 % progress.  The LiveView renders the preview from that event.
  """

  use Oban.Worker,
    queue: :ocr,
    unique: [period: 60, fields: [:worker, :args]],
    max_attempts: 3

  use Quire.Workers.Base

  alias Quire.Repo
  alias Quire.Documents.{Document, Revision}
  alias Quire.Forms.Detect

  @dpi 150

  @doc false
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: args}) do
    doc_id = args["doc_id"]
    revision_id = args["revision_id"]
    operation_id = args["operation_id"]

    with {:ok, doc} <- fetch_document(doc_id),
         {:ok, rev} <- fetch_revision(revision_id),
         %Quire.Storage.Ref{} = ref <- Revision.storage_ref(rev),
         {:ok, _source_bytes} <- Quire.Storage.get(ref) do
      report_progress(operation_id, doc_id, 10)

      case Detect.detect_ref(ref, dpi: @dpi) do
        {:ok, %{total: total, fields: fields}} ->
          report_progress(operation_id, doc_id, 90)

          Phoenix.PubSub.broadcast(
            Quire.PubSub,
            "document:#{doc_id}",
            {:auto_create_detections, operation_id, %{total: total, fields: fields}}
          )

          report_progress(operation_id, doc_id, 100)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, "no storage ref on revision #{revision_id}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Progress reporting ──────────────────────────────────────────────

  defp report_progress(nil, _doc_id, _pct), do: :ok

  defp report_progress(operation_id, doc_id, pct) do
    Quire.Workers.Base.report_progress(operation_id, doc_id, pct)
  end

  # ── DB helpers ───────────────────────────────────────────────────────

  defp fetch_document(doc_id) do
    case Repo.get(Document, doc_id) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  defp fetch_revision(revision_id) do
    case Repo.get(Revision, revision_id) do
      nil -> {:error, :not_found}
      rev -> {:ok, rev}
    end
  end
end
