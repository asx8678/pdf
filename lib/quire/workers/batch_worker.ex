defmodule Quire.Workers.BatchWorker do
  @moduledoc ~S"""
  Applies one recipe step to one file (§9.2, T-087).

  Each job handles a single (file, step) pair: the file bytes are decoded,
  the step's conversion runs (compress, PDF/A, split, image→PDF), and the
  result is ingested as a new document. Every job writes its own
  `operations` row with live progress via `Quire.Operations` (T-086).

  Runs on the `:batch` queue with concurrency 1 (§7.5) so N files never
  spawn more conversions than the laptop can handle.
  """

  use Oban.Worker,
    queue: :batch,
    unique: [period: 120, fields: [:worker, :args]],
    max_attempts: 2

  alias Quire.Operations
  alias Quire.Repo

  @impl true
  def perform(%Oban.Job{args: args}) do
    user_id = args["user_id"]
    filename = args["filename"]
    bytes = Base.decode64!(args["bytes"])
    step = args["step"]

    :ok = ensure_scope_doc!(user_id)

    with {:ok, op_id} <-
           Operations.start(nil_scope_doc(), user_id, "batch:" <> step_name(step), %{
             filename: filename,
             step: step
           }),
         {:ok, out_bytes} <- apply_step(bytes, step, filename) do
      case ingest_output(user_id, filename, step, out_bytes) do
        {:ok, _doc} ->
          Operations.finish(op_id, nil_scope_doc())
          emit_telemetry(:completed, %{filename: filename, step: step_name(step)})
          :ok

        {:error, reason} ->
          Operations.fail(op_id, nil_scope_doc(), reason)
          {:error, reason}
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  # operations.document_id is NOT NULL and FK-references documents, but a
  # batch run is not tied to a single document — each (file, step) job writes
  # its own row anchored to a well-known scope document (the all-zero UUID).
  # Create that row once; later jobs conflict on the primary key and no-op.
  defp ensure_scope_doc!(user_id) do
    doc_bin = uuid_bin!(nil_scope_doc())
    user_bin = uuid_bin!(user_id)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO documents (id, user_id, title, source_format, page_count, inserted_at, updated_at)
      VALUES ($1, $2, 'Batch scope', 'batch', 0, now(), now())
      ON CONFLICT (id) DO NOTHING
      """,
      [doc_bin, user_bin]
    )

    :ok
  end

  defp uuid_bin!(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> bin
      :error -> id
    end
  end

  @doc false
  def apply_step(bytes, %{"id" => "compress"} = step, _filename) do
    preset = String.to_atom(Map.get(step, "preset", "medium") || "medium")
    Quire.Compress.compress(bytes, preset: preset)
  end

  def apply_step(bytes, %{"id" => "pdfa"}, _filename) do
    case Quire.PdfA.convert(bytes) do
      {:ok, out, _report} -> {:ok, out}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_step(bytes, %{"id" => "split"} = step, filename) do
    n =
      case Integer.parse(Map.get(step, "every_n", "5") || "5") do
        {n, ""} when n >= 1 -> n
        _ -> 5
      end

    with {:ok, outputs} <- Quire.Split.split(bytes, {:every_n, n}, name: Path.rootname(filename)) do
      Quire.Split.zip_outputs(outputs, Path.rootname(filename) <> "-split.zip")
    end
  end

  def apply_step(bytes, %{"id" => "image_to_pdf"} = step, _filename) do
    deskew = Map.get(step, "deskew", true) != false
    contrast = Map.get(step, "contrast", "auto")
    Quire.Scan.image_to_pdf(bytes, deskew: deskew, contrast: String.to_atom(contrast))
  end

  def apply_step(_bytes, step, _filename), do: {:error, {:unknown_step, step}}

  # ── Persistence ────────────────────────────────────────────────────────

  defp ingest_output(user_id, filename, step, out_bytes) do
    title = "#{Path.rootname(filename)} — #{step_name(step)}"

    Quire.Documents.ingest(out_bytes, %{id: user_id, user: %{id: user_id}}, title: title)
  end

  defp step_name(%{"id" => id}), do: id
  defp step_name(_), do: "unknown"

  # Batch jobs are not tied to a single source document; use a nil doc scope.
  defp nil_scope_doc, do: "00000000-0000-0000-0000-000000000000"

  defp emit_telemetry(event, metadata) do
    :telemetry.execute([:quire, :batch, event], %{}, metadata)
  rescue
    _ -> :ok
  end
end
