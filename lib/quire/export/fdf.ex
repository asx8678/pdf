defmodule Quire.Export.FDF do
  @moduledoc """
  Export annotations as FDF (Forms Data Format, PDF 1.2).

  FDF is a small text format derived from PDF syntax.  This module
  generates a valid FDF file containing all annotations for a document,
  which can be imported into Adobe Acrobat or other PDF tools.

  No external libraries are used — the format is pure string/binary
  construction.
  """

  alias Quire.Repo

  import Ecto.Query

  @doc """
  Generate FDF content for all annotations on a document.

  Returns `{:ok, fdf_binary}` or `{:error, reason}`.
  """
  @spec generate(document_id :: String.t()) :: {:ok, binary()} | {:error, term()}
  def generate(document_id) do
    annotations = load_annotations(document_id)
    replies = load_replies(annotation_ids(annotations))
    {:ok, build_fdf(annotations, replies)}
  end

  @doc """
  Generate FDF content from pre-loaded annotation data.

  Useful for testing or when annotations are already in memory.
  """
  @spec generate_from_data(list(), map()) :: binary()
  def generate_from_data(annotations, replies_by_annot_id \\ %{}) do
    build_fdf(annotations, replies_by_annot_id)
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

  # ── FDF construction ──────────────────────────────────────────────────

  defp build_fdf(annotations, replies) do
    annot_entries =
      annotations
      |> Enum.map(fn a -> annotation_entry(a, Map.get(replies, a.id, [])) end)
      |> Enum.join("\n")

    header = "%FDF-1.2\n"

    objects = """
    1 0 obj
    << /FDF << /Annots [
    #{annot_entries}
    ] >> >>
    endobj
    """

    offset = byte_size(header) + byte_size(objects)

    xref_entry =
      String.pad_leading(Integer.to_string(byte_size(header)), 10, "0") <> " 00000 n \n"

    xref = "xref\n0 2\n0000000000 65535 f \n#{xref_entry}"

    trailer = "trailer\n<< /Root 1 0 R /Size 2 >>\n"
    startxref = "startxref\n#{offset}\n%%EOF\n"

    header <> objects <> xref <> trailer <> startxref
  end

  # ── Annotation entry ──────────────────────────────────────────────────

  defp annotation_entry(annot, replies) do
    subtype = annot_subtype(annot.kind)
    rect = format_rect(annot.rect)
    contents = pdf_escape(to_string(annot.contents || ""))
    author = pdf_escape(to_string(annot.author || ""))
    date = format_date(annot.inserted_at)
    color = format_color(annot.color)

    lines = [
      "<<",
      "  /Type /Annot",
      "  /Subtype /#{subtype}",
      "  /Rect [#{rect}]",
      "  /Contents (#{contents})",
      "  /P #{annot.page_index}",
      "  /T (#{author})",
      "  /CreationDate (#{date})"
    ]

    lines =
      if color, do: lines ++ ["  /C [#{color}]"], else: lines

    lines =
      if annot.opacity && annot.opacity < 1.0,
        do: lines ++ ["  /CA #{annot.opacity}"],
        else: lines

    flags = annot.flags || %{}

    lines =
      if Map.get(flags, "resolved", false),
        do: lines ++ ["  /F 4"],
        else: lines

    lines =
      if replies != [] do
        reply_parts =
          Enum.map(replies, fn r ->
            rb = pdf_escape(to_string(r.body || ""))
            rd = format_date(r.inserted_at)

            "<< /Type /Annot /Subtype /Text /Contents (#{rb}) /CreationDate (#{rd}) /IRT #{annot.id} >>"
          end)

        lines ++ ["  /Annots [#{Enum.join(reply_parts, "\n    ")}]"]
      else
        lines
      end

    Enum.join(lines, "\n") <> "\n>>"
  end

  # ── PDF helpers ────────────────────────────────────────────────────────

  defp annot_subtype("highlight"), do: "Highlight"
  defp annot_subtype("underline"), do: "Underline"
  defp annot_subtype("strikethrough"), do: "StrikeOut"
  defp annot_subtype("squiggly"), do: "Squiggly"
  defp annot_subtype("sticky_note"), do: "Text"
  defp annot_subtype("free_text"), do: "FreeText"
  defp annot_subtype("free_text_callout"), do: "FreeText"
  defp annot_subtype("ink"), do: "Ink"
  defp annot_subtype("stamp"), do: "Stamp"
  defp annot_subtype("signature"), do: "Stamp"
  defp annot_subtype("line"), do: "Line"
  defp annot_subtype("arrow"), do: "Line"
  defp annot_subtype("double_arrow"), do: "Line"
  defp annot_subtype("dimension"), do: "Line"
  defp annot_subtype("oval"), do: "Circle"
  defp annot_subtype("rectangle"), do: "Square"
  defp annot_subtype("polygon"), do: "Polygon"
  defp annot_subtype("cloud"), do: "Polygon"
  defp annot_subtype("polyline"), do: "PolyLine"
  defp annot_subtype("file_attachment"), do: "FileAttachment"
  defp annot_subtype("measure_distance"), do: "Line"
  defp annot_subtype("measure_perimeter"), do: "Polygon"
  defp annot_subtype("measure_area"), do: "Polygon"
  defp annot_subtype("whiteout"), do: "Square"
  defp annot_subtype(other), do: Macro.camelize(other)

  defp format_rect(nil), do: "0 0 0 0"

  defp format_rect(%{"left" => l, "bottom" => b, "right" => r, "top" => t}),
    do: "#{l} #{b} #{r} #{t}"

  defp format_rect(%{left: l, bottom: b, right: r, top: t}), do: "#{l} #{b} #{r} #{t}"

  defp format_rect(rect) when is_map(rect) do
    ~w(left bottom right top)
    |> Enum.map(&Map.get(rect, &1, 0))
    |> Enum.join(" ")
  end

  defp format_rect(_), do: "0 0 0 0"

  defp format_color(nil), do: nil

  defp format_color(<<?#, r::2-bytes, g::2-bytes, b::2-bytes>>) do
    {rv, _} = Integer.parse(r, 16)
    {gv, _} = Integer.parse(g, 16)
    {bv, _} = Integer.parse(b, 16)
    "#{Float.round(rv / 255, 4)} #{Float.round(gv / 255, 4)} #{Float.round(bv / 255, 4)}"
  end

  defp format_color(%{"r" => r, "g" => g, "b" => b}), do: "#{r} #{g} #{b}"
  defp format_color(%{r: r, g: g, b: b}), do: "#{r} #{g} #{b}"
  defp format_color(_), do: nil

  defp format_date(nil), do: "D:00000000000000"

  defp format_date(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("D:%Y%m%d%H%M%S'00'")
  end

  defp format_date(dt) do
    format_date(DateTime.from_naive!(dt, "Etc/UTC"))
  rescue
    _ -> "D:00000000000000"
  end

  # In PDF string objects delimited by (...):
  #   \\  → literal backslash
  #   \( → literal left paren
  #   \) → literal right paren
  #   \n → newline
  #   \r → carriage return
  #   \t → tab
  defp pdf_escape(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end
