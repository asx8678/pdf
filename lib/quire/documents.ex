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
    doc = Repo.get(Document, id)

    cond do
      is_nil(doc) ->
        {:error, :not_found}

      doc.user_id != scope.id ->
        {:error, :forbidden}

      true ->
        {:ok, doc}
    end
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
end
