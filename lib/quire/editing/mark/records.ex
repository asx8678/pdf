defmodule Quire.Editing.Mark.Records do
  @moduledoc """
  Persists app-applied marks into the `text_edits` table (plan3.md §5.3).

  T-098 (remove page marks) removes only marks this app applied — i.e.
  rows written here. Each row records the document, the page, the mark
  kind, the placement rect, the typography, and the applied revision so
  removal can be scoped and re-applied.

  ## Schema resilience

  The `text_edits` table ships with the project migrations (§5.3), but a
  database created before this feature ran them may lack it. `record/4`
  therefore rescues `Postgrex.Error` (undefined table) and returns
  `{:error, :table_unavailable}` rather than crashing a save that would
  otherwise succeed — the stamp is already applied to the bytes at that
  point.
  """

  @doc """
  Records one applied mark per stamped page.

  ## Parameters

    * `document_id` — the document UUID
    * `revision_id` — the revision the mark was applied to (may be nil)
    * `kind` — the `text_edits` kind (`"page_number"`, `"watermark"`, …)
    * `pages` — list of `{page_index, text}` stamped pairs
    * `opts` — `:rect` (placement rect per page), `:style` (font/size/
      color/margin map), `:content` (per-row extra data), `:id` (stable
      mark id, stored in each row's content)

  Returns `{:ok, count}` or `{:error, reason}`.
  """
  @spec record(binary() | nil, binary() | nil, String.t(), [{non_neg_integer(), String.t()}], keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def record(document_id, revision_id, kind, pages, opts \\ []) do
    rows = Enum.map(pages, &row(document_id, revision_id, kind, &1, opts))

    case rows do
      [] ->
        {:ok, 0}

      _ ->
        do_insert(rows)
    end
  end

  defp row(document_id, revision_id, kind, {page_index, text}, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      document_id: document_id,
      page_index: page_index,
      kind: kind,
      rect: Keyword.get(opts, :rect),
      style: Keyword.get(opts, :style),
      content: content_map(opts, text),
      applied_revision_id: revision_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp content_map(opts, text) do
    base = %{"text" => text}

    case Keyword.get(opts, :content) do
      content when is_map(content) -> Map.merge(base, content)
      _ -> base
    end
  end

  defp do_insert(rows) do
    Quire.Repo.insert_all(Quire.Documents.TextEdit, rows)
    {:ok, length(rows)}
  rescue
    error in Postgrex.Error ->
      if table_missing?(error), do: {:error, :table_unavailable}, else: {:error, error}
  end

  defp table_missing?(%Postgrex.Error{postgres: %{code: :undefined_table}}), do: true
  defp table_missing?(_), do: false
end
