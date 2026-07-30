defmodule Quire.Export.SummaryPdf do
  @moduledoc """
  Generate a printable summary PDF listing all annotations on a document.

  Uses ExPdfium to create a new PDF document and render annotation
  information as text on letter-sized pages.  No browser round-trip is
  needed.

  Each annotation (and its replies) is rendered on its own page for
  simplicity and readability.
  """

  alias Quire.Repo

  import Ecto.Query

  @page_width 612.0
  @page_height 792.0
  @margin 54.0
  @line_height 14.0

  @doc """
  Generate a summary PDF for all annotations on a document.
  """
  @spec generate(document_id :: String.t()) :: {:ok, binary()} | {:error, term()}
  def generate(document_id) do
    annotations = load_annotations(document_id)
    replies = load_replies(annotation_ids(annotations))
    build_pdf(annotations, replies)
  end

  @doc """
  Generate a summary PDF from pre-loaded annotation data.
  """
  @spec generate_from_data(list(), map()) :: {:ok, binary()} | {:error, term()}
  def generate_from_data(annotations, replies_by_annot_id \\ %{}) do
    build_pdf(annotations, replies_by_annot_id)
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

  # ── PDF construction ──────────────────────────────────────────────────

  defp build_pdf([], _replies) do
    # No annotations — return a minimal one-page document with a message
    case ExPdfium.new() do
      {:ok, doc} ->
        try do
          {:ok, doc} = ExPdfium.add_page(doc, {612.0, 792.0})

          ExPdfium.draw_text(doc, 0, {@margin, 400.0}, "No annotations to display",
            font: :helvetica,
            size: 14.0,
            color: {0.5, 0.5, 0.5}
          )

          ExPdfium.save_to_bytes(doc)
        after
          ExPdfium.close(doc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_pdf(annotations, replies) do
    ExPdfium.new()
    |> case do
      {:ok, doc} ->
        try do
          doc = render_all(doc, annotations, replies)
          ExPdfium.save_to_bytes(doc)
        after
          ExPdfium.close(doc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Rendering loop ────────────────────────────────────────────────────

  defp render_all(doc, annotations, replies) do
    annotations
    |> Enum.with_index()
    |> Enum.reduce(doc, fn {annot, idx}, doc ->
      page_idx = add_annotation_page(doc, idx)

      doc =
        draw_page_header(doc, page_idx, idx)

      doc = draw_field(doc, page_idx, 2, "Type", kind_label(annot.kind))
      doc = draw_field(doc, page_idx, 3, "Page", "#{annot.page_index + 1}")
      doc = draw_field(doc, page_idx, 4, "Author", annot.author || "Unknown")
      doc = draw_field(doc, page_idx, 5, "Date", format_date_short(annot.inserted_at))
      doc = draw_field(doc, page_idx, 6, "Status", resolved_status(annot))

      doc = draw_content_block(doc, page_idx, 8, "Content", to_string(annot.contents || ""))

      annot_replies = Map.get(replies, annot.id, [])

      doc =
        if annot_replies != [] do
          Enum.reduce(annot_replies, doc, fn reply, doc ->
            reply_y = reply_start_y(doc, annot_replies, reply)
            draw_field(doc, page_idx, reply_y, "Reply", to_string(reply.body || ""))
          end)
        else
          doc
        end

      doc
    end)
  end

  # ── Page management ───────────────────────────────────────────────────

  defp add_annotation_page(doc, _idx) do
    {:ok, doc} = ExPdfium.add_page(doc, {612.0, 792.0})
    {:ok, count} = ExPdfium.page_count(doc)
    count - 1
  end

  defp draw_page_header(doc, page_idx, annot_idx) do
    {:ok, doc} =
      ExPdfium.draw_text(
        doc,
        page_idx,
        {@margin, @page_height - @margin},
        "Annotation ##{annot_idx + 1}",
        font: :helvetica_bold,
        size: 16.0,
        color: {0.15, 0.15, 0.15}
      )

    doc
  end

  # ── Field drawing ─────────────────────────────────────────────────────

  defp draw_field(doc, page_idx, line_num, label, value) do
    y = @page_height - @margin - 30.0 - line_num * @line_height

    {:ok, doc} =
      ExPdfium.draw_text(doc, page_idx, {@margin, y}, "#{label}:",
        font: :helvetica_bold,
        size: 10.0,
        color: {0.3, 0.3, 0.3}
      )

    {:ok, doc} =
      ExPdfium.draw_text(doc, page_idx, {@margin + 55.0, y}, truncate_text(value, 65),
        font: :helvetica,
        size: 10.0,
        color: {0.15, 0.15, 0.15}
      )

    doc
  end

  defp draw_content_block(doc, page_idx, start_line, label, text) do
    y = @page_height - @margin - 30.0 - start_line * @line_height

    {:ok, doc} =
      ExPdfium.draw_text(doc, page_idx, {@margin, y}, "#{label}:",
        font: :helvetica_bold,
        size: 10.0,
        color: {0.3, 0.3, 0.3}
      )

    # Draw content wrapped
    {_doc, _last_y} =
      draw_wrapped(
        doc,
        page_idx,
        @margin,
        y - @line_height,
        text,
        @page_width - 2 * @margin,
        10.0
      )

    doc
  end

  defp draw_wrapped(doc, _page_idx, _x, y, _text, _max_width, _font_size) when y < @margin do
    {doc, y}
  end

  defp draw_wrapped(doc, page_idx, x, y, text, max_width, font_size) when byte_size(text) > 0 do
    char_width = font_size * 0.5
    chars_per_line = max(1, trunc(max_width / char_width))

    if String.length(text) <= chars_per_line do
      {:ok, doc} =
        ExPdfium.draw_text(doc, page_idx, {x, y}, text,
          font: :helvetica,
          size: font_size,
          color: {0.15, 0.15, 0.15}
        )

      {doc, y}
    else
      # Find a good break near the limit
      {line, rest} = split_line(text, chars_per_line)

      {:ok, doc} =
        ExPdfium.draw_text(doc, page_idx, {x, y}, line,
          font: :helvetica,
          size: font_size,
          color: {0.15, 0.15, 0.15}
        )

      draw_wrapped(doc, page_idx, x, y - @line_height, rest, max_width, font_size)
    end
  end

  defp draw_wrapped(doc, _page_idx, _x, y, _text, _max_width, _font_size) do
    {doc, y}
  end

  defp split_line(text, max_chars) do
    candidate = String.slice(text, 0, max_chars)
    rest = String.slice(text, max_chars..-1//1)

    case String.last(candidate) do
      " " ->
        {String.trim(candidate), rest}

      _ ->
        case String.split(text, ~r/\s+/, parts: 2) do
          [l, r] ->
            if String.length(l) <= max_chars and String.length(l) > 0 do
              {l, r}
            else
              {candidate, rest}
            end

          _ ->
            {candidate, rest}
        end
    end
  end

  defp reply_start_y(_doc, replies, reply) do
    idx = Enum.find_index(replies, &(&1.id == reply.id)) || 0
    10 + idx
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp kind_label(kind) do
    kind
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp resolved_status(annot) do
    flags = annot.flags || %{}
    if Map.get(flags, "resolved", false), do: "Resolved", else: "Open"
  end

  defp format_date_short(nil), do: ""

  defp format_date_short(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y-%m-%d")
  end

  defp format_date_short(dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y-%m-%d")
  rescue
    _ -> ""
  end

  defp truncate_text(text, max_len) when byte_size(text) > max_len do
    String.slice(text, 0, max_len - 1) <> "\u2026"
  end

  defp truncate_text(text, _max_len), do: text
end
