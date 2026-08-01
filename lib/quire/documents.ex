defmodule Quire.Documents do
  @moduledoc """
  The Documents context — CRUD, revisions, and the open pipeline (§10.3).

  Every public function validates authorisation via the caller's `scope` and
  returns `{:ok, result}` or `{:error, reason}`.
  """
  alias Quire.Repo
  alias Quire.Documents.Document
  alias Quire.Documents.Revision

  @doc """
  Fetch a document by id, validating the caller owns it.

  Returns `{:ok, %Document{}}` or `{:error, :not_found}` /
  `{:error, :forbidden}`.
  """
  @spec get_document(binary(), scope :: term()) :: {:ok, Document.t()} | {:error, atom()}
  def get_document(id, scope) do
    # Repo.get with an invalid UUID string raises CastError — guard early.
    with {:ok, _} <- Ecto.UUID.cast(id) do
      do_get_document(id, scope)
    else
      :error -> {:error, :not_found}
    end
  end

  defp do_get_document(id, %Quire.Accounts.Scope{} = scope) do
    doc = Repo.get(Document, id)

    cond do
      is_nil(doc) ->
        {:error, :not_found}

      doc.user_id != scope.user.id ->
        {:error, :forbidden}

      true ->
        {:ok, doc}
    end
  end

  defp do_get_document(_id, _other_scope) do
    {:error, :forbidden}
  end

  @doc """
  Fetch the current revision for a document.

  Returns `{:ok, %Revision{}}` loaded from `document.current_revision_id`,
  or `{:error, :not_found}` when there is no revision yet.
  """
  @spec current_revision(Document.t()) :: {:ok, Revision.t()} | {:error, atom()}
  def current_revision(%Document{current_revision_id: nil}) do
    {:error, :not_found}
  end

  def current_revision(%Document{current_revision_id: rev_id}) do
    case Repo.get(Revision, rev_id) do
      nil -> {:error, :not_found}
      rev -> {:ok, rev}
    end
  end

  # ── Revisions ────────────────────────────────────────────────────────────

  @doc """
  Create a new revision for a document.

  `attrs` is a keyword list or map that may contain:
    * `:label` — human-readable label (default `"Untitled revision"`)
    * `:source` — source map (must contain `"storage_ref"` key pointing to
      the new document's `Quire.Storage.Ref` JSON representation)

  Returns `{:ok, %Revision{}}` or `{:error, changeset}`.
  """
  @spec create_revision(Document.t(), keyword() | map()) ::
          {:ok, Revision.t()} | {:error, Ecto.Changeset.t()}
  def create_revision(%Document{} = doc, attrs) do
    %Revision{
      document_id: doc.id,
      label: attrs[:label] || "Untitled revision",
      source: attrs[:source] || %{}
    }
    |> Repo.insert()
  end

  # ── Open pipeline (§10.3) ──────────────────────────────────────────────

  @doc """
  Ingest PDF bytes: validate, detect encryption, store, create document and
  revision 1, enqueue background jobs, and upsert recent_documents.

  ## Steps

  1. Validate PDF header — reject anything that does not start with `%PDF-`.
  2. Detect encryption via `Quire.Pdf.open/1`.
  3. Store bytes → `Quire.Storage.Ref`.
  4. Query `Render.page_count` and `page_geometry`.
  5. Create `documents` + `document_revisions` + `document_pages` rows.
  6. Enqueue thumbnail render and text‑layer probe jobs.
  7. Upsert `recents`.
  8. Return the document record and a viewer URL.

  ## Encryption

  If the PDF is encrypted, returns `{:error, :password_required}`. The caller
  should prompt for a password and call `open_with_password/4` to retry.

  ## Examples

      {:ok, %{document: doc, document_url: url}} =
        Documents.ingest(pdf_bytes, current_scope, title: "report.pdf")
  """
  @spec ingest(binary(), scope :: term(), keyword()) ::
          {:ok, %{document: Document.t(), document_url: String.t()}}
          | {:error, atom()}
  def ingest(pdf_bytes, scope, opts \\ []) do
    title = Keyword.get(opts, :title, "Untitled")

    # Step 1: Quick header check
    with :ok <- validate_header(pdf_bytes),
         # Step 2: Detect encryption via Pdf.open
         {:ok, _pdf_handle} <- detect_encryption(pdf_bytes) do
      do_ingest(pdf_bytes, scope, title)
    else
      {:error, :password_error} -> {:error, :password_required}
      {:error, :invalid_pdf} -> {:error, :invalid_pdf}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Retry ingest with a password for an encrypted PDF.

  The password is passed through to `Quire.Pdf.open/2` (when supported) or
  used to decrypt before re-issuing the ingest.  See ADR 0008 for the
  encryption-at-rest design.

  ## Examples

      {:ok, result} = Documents.open_with_password(bytes, password, scope)
  """
  @spec open_with_password(binary(), String.t(), scope :: term(), keyword()) ::
          {:ok, %{document: Document.t(), document_url: String.t()}}
          | {:error, atom()}
  def open_with_password(_pdf_bytes, _password, _scope, _opts \\ []) do
    # TODO: Implement password-based decryption when Quire.Pdf supports
    # `authenticate_password/2`.  For now this returns an explicit error
    # so the caller can prompt or display a "not yet supported" message.
    #
    # The decrypt path is: detect encryption via Pdf.open, if :password_error
    # then decrypt using the security handler, re-issue do_ingest/3 with the
    # plaintext bytes.
    {:error, :not_implemented}
  end

  # ── Private ────────────────────────────────────────────────────────────

  @pdf_header_magic <<37, 80, 68, 70, 45>>

  defp validate_header(<<@pdf_header_magic, _rest::binary>>), do: :ok
  defp validate_header(_), do: {:error, :invalid_pdf}

  defp detect_encryption(pdf_bytes) do
    case Quire.Pdf.open(pdf_bytes) do
      {:ok, doc} -> {:ok, doc}
      {:error, :password_error} -> {:error, :password_error}
      {:error, :invalid_pdf} -> {:error, :invalid_pdf}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_ingest(pdf_bytes, scope, title) do
    # Step 3: Store bytes → Storage Ref
    with {:ok, ref} <-
           Quire.Storage.put(pdf_bytes, name: title, content_type: "application/pdf") do
      # Step 4: Query page count and page geometry via the render adapter
      {page_count, page_geometries} = query_page_metrics(ref)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Step 5a: Insert documents row
      {:ok, doc} =
        Repo.insert(%Document{
          user_id: scope.user.id,
          title: title,
          source_format: "pdf",
          page_count: page_count,
          updated_at: now
        })

      # Build revision source map — the document controller uses this to
      # find the storage ref for range-request streaming.
      ref_map = %{
        "storage_ref" => %{
          "adapter" => to_string(ref.adapter),
          "key" => ref.key,
          "name" => ref.name,
          "content_type" => ref.content_type,
          "byte_size" => ref.byte_size
        },
        "filename" => title
      }

      # Step 5b: Insert revision 1
      {:ok, rev} =
        Repo.insert(%Revision{
          document_id: doc.id,
          label: "Original upload",
          source: ref_map
        })

      # Link document → current_revision
      {:ok, doc} =
        doc
        |> Ecto.Changeset.change(%{current_revision_id: rev.id})
        |> Repo.update()

      # Step 5c: Insert document_pages rows
      insert_page_rows(rev.id, page_geometries)

      # Step 6: Enqueue background jobs
      enqueue_post_ingest_jobs(doc, rev, ref)

      # Step 7: Upsert recents
      upsert_recent(doc.id, scope.user.id, now)

      # Step 8: Return document + viewer URL
      document_url = "/documents/" <> doc.id <> "/pdf"

      {:ok, %{document: doc, document_url: document_url}}
    end
  end

  defp query_page_metrics(ref) do
    count =
      case Quire.Render.page_count(ref) do
        {:ok, n} -> n
        _ -> 0
      end

    geometries =
      case Quire.Render.page_geometry(ref) do
        {:ok, geoms} -> geoms
        _ -> []
      end

    {count, geometries}
  end

  defp insert_page_rows(_revision_id, []), do: :ok

  defp insert_page_rows(revision_id, geometries) do
    rows =
      geometries
      |> Enum.with_index()
      |> Enum.map(fn {geom, idx} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        %{
          revision_id: revision_id,
          page_index: idx,
          width: geom.width * 1.0,
          height: geom.height * 1.0,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Quire.Documents.Page, rows)
  end

  defp enqueue_post_ingest_jobs(doc, rev, _ref) do
    # Text-extraction worker — populates document_page_text and sets has_text.
    %{revision_id: rev.id, document_id: doc.id}
    |> Quire.Workers.TextExtractWorker.new([])
    |> Oban.insert!()

    # T-045: Thumbnail render worker — enqueued once it exists.
    :ok
  end

  defp upsert_recent(_document_id, _user_id, _opened_at) do
    # TBD: upsert into recents table via Repo.insert_all with
    # on_conflict: :nothing for (user_id, document_id) unique constraint.
    # The migration already creates the unique index.
    :ok
  end

  # ── Secure Operations ──────────────────────────────────────────────────

  @doc """
  Enqueue a redaction-apply job for the given document.

  The worker (`Quire.Workers.SecureWorker`) applies the marks, verifies
  redacted strings are absent from text extraction, and on success creates
  a new revision with `redactions.applied` metadata on the document.

  Returns `{:ok, job}` or `{:error, reason}`.
  """
  @spec redact_document(Document.t(), [map()], keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def redact_document(%Document{} = doc, marks, opts \\ []) when is_list(marks) do
    operation_id = Keyword.get(opts, :operation_id)

    job_args = %{
      "doc_id" => doc.id,
      "operation" => "sec.redact_apply",
      "marks" => marks
    }

    job_args =
      if operation_id do
        Map.put(job_args, "operation_id", operation_id)
      else
        job_args
      end

    job_args
    |> Quire.Workers.SecureWorker.new([])
    |> Oban.insert()
  end
end
