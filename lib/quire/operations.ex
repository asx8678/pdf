defmodule Quire.Operations do
  @moduledoc ~S"""
  Operation rows and live progress for conversions (§9.2, T-086).

  Every conversion in the app writes an `operations` row (id, kind, status,
  progress, input/result/error, timings) and broadcasts progress on PubSub
  topic `"document:{doc_id}"`:

    * `{:operation_progress, id, pct}` — monotonic 0..100
    * `{:operation_completed, id, doc_id}` — finished at 100
    * `{:operation_failed, id, doc_id, reason}` — plain-language cause

  Duration telemetry is emitted as `[:quire, :operation, :completed|:failed]`
  with `duration` (microseconds) and metadata.

  The `operations` table is created by the
  `create_editing_forms_security_jobs_cloud_tables` migration; rows are
  written through the raw Postgrex layer (UUIDs dumped to 16 bytes).
  """

  alias Quire.Repo

  @doc """
  Inserts an `operations` row and broadcasts 0% progress.

  Returns `{:ok, operation_id}` (a UUID string).
  """
  @spec start(binary(), binary(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def start(doc_id, user_id, kind, input \\ %{}) do
    operation_id = Ecto.UUID.generate()

    with {:ok, op} <- uuid_param(operation_id),
         {:ok, doc} <- uuid_param(doc_id),
         {:ok, user} <- uuid_param(user_id),
         {:ok, _} <- insert_operation(op, doc, user, kind, input) do
      broadcast("document:#{doc_id}", {:operation_progress, operation_id, 0})
      {:ok, operation_id}
    end
  end

  @doc "Updates progress (0..100) and broadcasts it."
  @spec progress(String.t(), binary(), non_neg_integer()) :: :ok
  def progress(operation_id, doc_id, pct) when is_integer(pct) and pct in 0..100 do
    with {:ok, op} <- uuid_param(operation_id),
         {:ok, _} <-
           Ecto.Adapters.SQL.query(
             Repo,
             "UPDATE operations SET progress = $1, updated_at = now() WHERE id = $2",
             [pct, op]
           ) do
      broadcast("document:#{doc_id}", {:operation_progress, operation_id, pct})
    end

    :ok
  end

  @doc "Marks the operation completed at 100% and emits duration telemetry."
  @spec finish(String.t(), binary(), map()) :: :ok
  def finish(operation_id, doc_id, result \\ %{}) do
    with {:ok, op} <- uuid_param(operation_id),
         {:ok, _} <-
           Ecto.Adapters.SQL.query(
             Repo,
             "UPDATE operations SET progress = 100, status = 'completed', result = $1, finished_at = now(), updated_at = now() WHERE id = $2",
             [encode(result), op]
           ) do
      duration = operation_duration(op)

      :telemetry.execute(
        [:quire, :operation, :completed],
        %{duration: duration},
        %{operation_id: operation_id, doc_id: doc_id}
      )

      broadcast("document:#{doc_id}", {:operation_progress, operation_id, 100})
      broadcast("document:#{doc_id}", {:operation_completed, operation_id, doc_id})
    end

    :ok
  end

  @doc "Records a plain-language failure cause and emits duration telemetry."
  @spec fail(String.t(), binary(), term()) :: :ok
  def fail(operation_id, doc_id, reason) do
    message = friendly_error(reason)

    with {:ok, op} <- uuid_param(operation_id),
         {:ok, _} <-
           Ecto.Adapters.SQL.query(
             Repo,
             "UPDATE operations SET status = 'failed', error = $1, finished_at = now(), updated_at = now() WHERE id = $2",
             [encode(%{message: message}), op]
           ) do
      duration = operation_duration(op)

      :telemetry.execute(
        [:quire, :operation, :failed],
        %{duration: duration},
        %{operation_id: operation_id, doc_id: doc_id, error: message}
      )

      broadcast("document:#{doc_id}", {:operation_failed, operation_id, doc_id, message})
    end

    :ok
  end

  @doc """
  Ensures an operation exists for a worker run.

  Workers accept an optional `operation_id` in their args; when absent they
  create their own row keyed to the job so the UI still shows live progress.
  Returns `{operation_id, doc_id, user_id}` — all resolved.
  """
  @spec ensure_started(map(), String.t()) ::
          {:ok, String.t(), String.t(), String.t()} | {:error, term()}
  def ensure_started(args, kind) do
    doc_id = args["doc_id"]
    user_id = args["user_id"] || doc_user_id(doc_id)

    if doc_id && user_id do
      case args["operation_id"] do
        id when is_binary(id) and id != "" ->
          {:ok, id, doc_id, user_id}

        _ ->
          case start(doc_id, user_id, kind, %{job: args["filename"] || to_string(kind)}) do
            {:ok, op_id} -> {:ok, op_id, doc_id, user_id}
            {:error, reason} -> {:error, reason}
          end
      end
    else
      {:error, :missing_scope}
    end
  end

  defp doc_user_id(doc_id) do
    case Ecto.UUID.dump(doc_id) do
      {:ok, bin} ->
        case Ecto.Adapters.SQL.query(
               Repo,
               "SELECT user_id FROM documents WHERE id = $1",
               [bin]
             ) do
          {:ok, %{rows: [[user_id | _]]}} -> user_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc false
  def friendly_error(reason) do
    case reason do
      %{message: msg} when is_binary(msg) -> msg
      {:invalid_image, msg} when is_binary(msg) -> msg
      {:invalid_pdf, msg} when is_binary(msg) -> msg
      {:zip_failed, r} -> "Could not package the output ZIP (#{inspect(r)})"
      :password_required -> "The document is password-protected"
      :invalid_pdf -> "The file is not a readable PDF"
      :not_found -> "The document could not be found"
      :no_pages -> "The document has no pages to process"
      msg when is_binary(msg) -> msg
      _other -> "The conversion failed (see logs for details)"
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp insert_operation(op, doc, user, kind, input) do
    Ecto.Adapters.SQL.query(
      Repo,
      "INSERT INTO operations (id, document_id, user_id, kind, status, progress, input, started_at, inserted_at, updated_at) VALUES ($1, $2, $3, $4, 'running', 0, $5, now(), now(), now())",
      [op, doc, user, kind, encode(input)]
    )
  end

  defp operation_duration(op) do
    case Ecto.Adapters.SQL.query(
           Repo,
           "SELECT extract(epoch from (now() - started_at)) * 1000000 FROM operations WHERE id = $1",
           [op]
         ) do
      {:ok, %{rows: [[seconds | _]]}} when is_number(seconds) -> round(seconds)
      _ -> 0
    end
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(Quire.PubSub, topic, message)
  rescue
    _ -> :ok
  end

  defp encode(value), do: Jason.encode!(value)

  defp uuid_param(id) when is_binary(id) and byte_size(id) == 16, do: {:ok, id}

  defp uuid_param(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> {:ok, bin}
      :error -> :error
    end
  end

  defp uuid_param(_), do: :error
end
