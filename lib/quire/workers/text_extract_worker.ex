defmodule Quire.Workers.TextExtractWorker do
  @moduledoc ~S"""
  Extracts text per page via `Render.extract_text/2` and populates
  `document_page_text` rows (§5.2).

  Also sets `document_pages.has_text` based on whether the page had non-empty
  text content — drives the "run OCR first" prompt (T-145).

  ## Idempotency

  The `(revision_id, page_index)` unique index on `document_page_text` ensures
  that a retry does not produce duplicate rows.  `on_conflict: :nothing` makes
  the second run a no-op.

  ## Queue

  Runs on the `:render` queue, serialised by PDFIUM_LOCK (§7.2).
  """

  use Oban.Worker,
    queue: :render,
    unique: [period: 60, fields: [:worker, :args]],
    max_attempts: 3

  import Ecto.Query

  alias Quire.Repo
  alias Quire.Documents.{Page, PageText, Revision}

  @doc false
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: args}) do
    revision_id = args["revision_id"]
    document_id = args["document_id"]
    operation_id = args["operation_id"]

    revision = Repo.get!(Revision, revision_id)
    ref = Revision.storage_ref(revision)

    if is_nil(ref) do
      {:error, "no storage ref on revision #{revision_id}"}
    else
      # Idempotency check — if page-text rows already exist, skip extraction.
      existing_count =
        Repo.aggregate(
          from(pt in PageText, where: pt.revision_id == ^revision_id),
          :count,
          :id
        )

      result =
        if existing_count == 0 do
          do_extract(ref, revision_id)
        else
          {:ok, :already_populated}
        end

      case result do
        {:ok, _} ->
          # Always update has_text — covers partial-failure edge case.
          update_has_text(revision_id)

          # Notify progress on document PubSub topic
          if operation_id do
            Quire.Workers.Base.report_progress(operation_id, document_id, 100)
          end

          :ok

        {:error, _reason} = err ->
          err
      end
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp do_extract(ref, revision_id) do
    with {:ok, page_results} <- Quire.Render.extract_text(ref) do
      now = DateTime.utc_now()

      rows =
        Enum.map(page_results, fn %{page: page_idx, spans: spans} ->
          spans = spans || []
          content = Enum.map_join(spans, "\n", fn span -> span[:text] || "" end)

          %{
            revision_id: revision_id,
            page_index: page_idx,
            content: content,
            spans:
              Enum.map(spans, fn s ->
                %{text: s[:text], bounds: s[:bounds]}
              end),
            inserted_at: now
          }
        end)

      Repo.insert_all(PageText, rows,
        on_conflict: :nothing,
        conflict_target: [:revision_id, :page_index]
      )

      {:ok, page_results}
    end
  end

  defp update_has_text(revision_id) do
    pages_with_text =
      Repo.all(
        from pt in PageText,
          where: pt.revision_id == ^revision_id and pt.content != "",
          select: pt.page_index
      )

    if pages_with_text != [] do
      Repo.update_all(
        from(p in Page,
          where: p.revision_id == ^revision_id and p.page_index in ^pages_with_text
        ),
        set: [has_text: true]
      )
    end
  end
end
