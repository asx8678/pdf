defmodule Quire.Export.CSV do
  @moduledoc """
  Export annotations as CSV (UTF-8 with BOM for Excel compatibility).

  Columns: Page, Type, Author, Content, Date, Status, Replies

  Each annotation is one row.  Reply rows are indented under their parent
  annotation with the annotation ID as reference.

  No external CSV library is used — the format is simple string construction
  with proper escaping.
  """

  alias Quire.Repo

  import Ecto.Query

  @columns ~w(Page Type Author Content Date Status Replies ID)

  @doc """
  Generate CSV content for all annotations on a document.

  Returns `{:ok, csv_binary}` with UTF-8 BOM for Excel compatibility.
  """
  @spec generate(document_id :: String.t()) :: {:ok, binary()} | {:error, term()}
  def generate(document_id) do
    annotations = load_annotations(document_id)
    replies = load_replies(annotation_ids(annotations))
    {:ok, build_csv(annotations, replies)}
  end

  @doc """
  Generate CSV content from pre-loaded annotation data.
  """
  @spec generate_from_data(list(), map()) :: binary()
  def generate_from_data(annotations, replies_by_annot_id \\ %{}) do
    build_csv(annotations, replies_by_annot_id)
  end

  # ── Data loading ────────────────────────────────────────────────────────

  defp load_annotations(doc_id) do
    Repo.all(
      from a in "annotations",
        where: a.document_id == ^doc_id,
        order_by: [asc: a.page_index, asc: a.inserted_at]
    )
  end

  defp load_replies([]), do: %{}

  defp load_replies(annot_ids) do
    replies =
      Repo.all(
        from r in {"annotation_replies", Quire.Documents.AnnotationReply},
          where: r.annotation_id in ^annot_ids,
          order_by: [asc: r.inserted_at]
      )

    Enum.group_by(replies, & &1.annotation_id)
  end

  defp annotation_ids(annotations), do: Enum.map(annotations, & &1.id)

  # ── CSV construction ──────────────────────────────────────────────────

  defp build_csv(annotations, replies) do
    header = Enum.map(@columns, &escape_csv/1) |> Enum.join(",")

    rows =
      Enum.flat_map(annotations, fn a ->
        annot_row = annotation_row(a)
        annot_replies = Map.get(replies, a.id, [])

        reply_rows =
          Enum.map(annot_replies, fn r ->
            reply_row(r, a.id)
          end)

        [annot_row | reply_rows]
      end)

    # UTF-8 BOM for Excel compatibility
    <<0xEF, 0xBB, 0xBF>> <> header <> "\n" <> Enum.join(rows, "\n") <> "\n"
  end

  defp annotation_row(annot) do
    page = annot.page_index + 1
    type = kind_label(annot.kind)
    author = annot.author || ""
    content = annot.contents || ""
    date = format_date(annot.inserted_at)
    flags = annot.flags || %{}
    status = if Map.get(flags, "resolved", false), do: "Resolved", else: "Open"
    id = annot.id

    row_values(page, type, author, content, date, status, "", id)
  end

  defp reply_row(reply, parent_id) do
    row_values(
      "",
      "Reply",
      "",
      reply.body || "",
      format_date(reply.inserted_at),
      "",
      parent_id,
      reply.id
    )
  end

  defp row_values(page, type, author, content, date, status, parent_id, id) do
    [
      page,
      type,
      author,
      content,
      date,
      status,
      parent_id,
      id
    ]
    |> Enum.map(&escape_csv/1)
    |> Enum.join(",")
  end

  # ── Format helpers ─────────────────────────────────────────────────────

  defp kind_label(kind) do
    kind
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_date(nil), do: ""

  defp format_date(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_date(dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  rescue
    _ -> ""
  end

  # CSV escaping: wrap in quotes if contains comma, quote, or newline;
  # double any embedded quotes.
  defp escape_csv(value) when is_integer(value), do: Integer.to_string(value)
  defp escape_csv(value) when is_float(value), do: Float.to_string(value)

  defp escape_csv(value) do
    s = to_string(value)

    if String.contains?(s, [",", "\"", "\n", "\r"]) do
      ~s["#{String.replace(s, ~S["], ~S[""])}"]
    else
      s
    end
  end
end
