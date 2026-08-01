defmodule Quire.Workers.SecureWorker do
  @moduledoc ~S"""
  Oban worker for server-side secure document operations — redaction,
  metadata stripping, encryption, and sanitisation (§9.7).

  Runs on the `:secure` queue, serialised (concurrency 1). Every operation
  is destructive and must produce exactly one new revision.

  ## Queue

  Runs on `:secure`, concurrency 1 — at most one secure transform per
  document at a time.

  ## Job args

  Common:
    * `"doc_id"` — required, UUID
    * `"operation"` — discriminator: `"sec.redact_apply"`, `"sec.strip_metadata"`,
      `"sec.encrypt"`, `"sec.sanitize"`, etc.
    * `"operation_id"` — optional, for progress reporting

  Redaction-specific:
    * `"marks"` — list of `%{"page" => int, "rect" => [x0, y0, x1, y1]}`
  """

  use Oban.Worker, queue: :secure
  use Quire.Workers.Base, queue: :secure

  alias Quire.Repo
  alias Quire.Documents.{Document, Revision}
  alias Quire.Storage.Ref

  # ── Oban callback ──────────────────────────────────────────────────────

  @doc false
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: args}) do
    operation = args["operation"]

    case operation do
      "sec.redact_apply" ->
        perform_redact_apply(args)

      _ ->
        {:error, "unknown secure operation: #{inspect(operation)}"}
    end
  end

  # ── Redact Apply ──────────────────────────────────────────────────────

  defp perform_redact_apply(args) do
    doc_id = args["doc_id"]
    operation_id = args["operation_id"]
    marks = normalize_marks(args["marks"] || [])

    if marks == [] do
      if operation_id do
        Quire.Workers.Base.report_progress(operation_id, doc_id, 100)
      end

      {:error, "no marks to redact"}
    else
      with {:ok, doc} <- fetch_document(doc_id),
           {:ok, rev} <- Quire.Documents.current_revision(doc),
           %Ref{} = ref <- Revision.storage_ref(rev),
           {:ok, source_bytes} <- Quire.Storage.get(ref),
           {:ok, redacted_bytes} <- Quire.SecurityHandler.Redact.apply(source_bytes, marks) do
        # Store the redacted document bytes.
        {:ok, new_ref} =
          Quire.Storage.put(redacted_bytes, name: doc.title, content_type: "application/pdf")

        # Build revision source map.
        source_map = %{
          "storage_ref" => %{
            "adapter" => to_string(new_ref.adapter),
            "key" => new_ref.key,
            "name" => new_ref.name,
            "content_type" => new_ref.content_type,
            "byte_size" => new_ref.byte_size
          },
          "filename" => doc.title
        }

        {:ok, new_rev} =
          Quire.Documents.create_revision(doc,
            label: "Redactions applied",
            source: source_map
          )

        # Update document metadata to track the redaction.
        {:ok, _updated_doc} = mark_redactions_applied(doc, new_rev.id)

        # Copy page caches and remap (identity map for redaction — all pages preserved).
        old_revision_id = rev.id
        preserved_map = Map.new(0..(doc.page_count - 1), fn i -> {i, i} end)

        Quire.Workers.TransformWorker.copy_page_caches(
          Repo,
          old_revision_id,
          new_rev.id,
          preserved_map
        )

        Quire.Workers.TransformWorker.remap_sidecar_indices(
          Repo,
          old_revision_id,
          new_rev.id,
          preserved_map
        )

        # Enqueue text extraction for the new revision.
        %{revision_id: new_rev.id, document_id: doc.id}
        |> Quire.Workers.TextExtractWorker.new([])
        |> Oban.insert!()

        # Broadcast revision on the document's PubSub topic.
        Phoenix.PubSub.broadcast(
          Quire.PubSub,
          "document:#{doc_id}",
          {:revision, new_rev}
        )

        if operation_id do
          Quire.Workers.Base.report_progress(operation_id, doc_id, 100)
        end

        :ok
      else
        {:error, :not_found} ->
          {:error, "document not found"}

        nil ->
          {:error, "no storage ref on current revision"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp fetch_document(doc_id) do
    case Repo.get(Document, doc_id) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  # Convert string-keyed job args to atom-keyed marks.
  defp normalize_marks(marks) when is_list(marks) do
    Enum.map(marks, fn m ->
      %{
        page: Map.get(m, "page") || Map.get(m, :page),
        rect: Map.get(m, "rect") || Map.get(m, :rect)
      }
    end)
  end

  # Set redactions.applied and redactions.applied_revision_id in
  # the document's metadata map.
  defp mark_redactions_applied(doc, revision_id) do
    now = DateTime.utc_now()

    metadata =
      doc.metadata
      |> Map.put("redactions", %{
        "applied" => true,
        "applied_at" => DateTime.to_iso8601(now),
        "applied_revision_id" => revision_id
      })

    doc
    |> Ecto.Changeset.change(%{metadata: metadata})
    |> Repo.update()
  end
end
