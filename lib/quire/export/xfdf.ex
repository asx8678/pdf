defmodule Quire.Export.XFDF do
  @moduledoc """
  Export and import annotations as XFDF (XML Forms Data Format).

  XFDF is an XML-based format designed for annotation interchange with
  PDF documents.  It supports all annotation types, replies, colors,
  flags, and page references.

  ## Export

      {:ok, xml} = Quire.Export.XFDF.generate(document_id)

  ## Import

      {:ok, count} = Quire.Export.XFDF.import(xml, document_id)

  No external XML library is needed for export (string/binary construction);
  import uses Saxy (already a project dependency) for XML parsing.
  """

  alias Quire.Repo

  import Ecto.Query

  @doc """
  Generate XFDF XML for all annotations on a document.
  """
  @spec generate(document_id :: String.t()) :: {:ok, binary()} | {:error, term()}
  def generate(document_id) do
    annotations = load_annotations(document_id)
    replies = load_replies(annotation_ids(annotations))
    {:ok, build_xfdf(annotations, replies)}
  end

  @doc """
  Generate XFDF XML from pre-loaded annotation data.
  """
  @spec generate_from_data(list(), map()) :: binary()
  def generate_from_data(annotations, replies_by_annot_id \\ %{}) do
    build_xfdf(annotations, replies_by_annot_id)
  end

  @doc """
  Import annotations from XFDF XML into a document.

  Creates annotation records in the database matching the XFDF content.
  Returns `{:ok, count}` where count is the number of annotations imported.
  """
  @spec import(binary(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def import(xml, document_id) do
    case Saxy.parse_string(xml, XFDFHandler, %{
           annots: [],
           stack: [],
           current_annot: nil,
           current_reply: nil,
           text: ""
         }) do
      {:ok, %{annots: annots}} ->
        count = insert_annotations(annots, document_id)
        {:ok, count}

      {:error, reason} ->
        {:error, reason}
    end
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

  # ── XFDF construction ─────────────────────────────────────────────────

  defp build_xfdf([], _replies) do
    ~s[<?xml version="1.0" encoding="UTF-8"?>\n<xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">\n  <annots />\n</xfdf>\n]
  end

  defp build_xfdf(annotations, replies) do
    annots_xml =
      annotations
      |> Enum.map(fn a -> annotation_element(a, Map.get(replies, a.id, [])) end)
      |> Enum.join("\n")

    [
      ~s[<?xml version="1.0" encoding="UTF-8"?>\n],
      ~s[<xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">\n],
      ~s[  <annots>\n],
      annots_xml,
      ~s[\n  </annots>\n],
      ~s[</xfdf>\n]
    ]
    |> IO.iodata_to_binary()
  end

  # ── Annotation XML element ─────────────────────────────────────────────

  defp annotation_element(annot, []) do
    single_annotation_xml(annot)
  end

  defp annotation_element(annot, replies) do
    lines = [single_annotation_xml(annot)]
    lines = lines ++ Enum.map(replies, &reply_element/1)

    [lines, ~s[    </#{xfdf_subtype(annot.kind)}>]]
    |> IO.iodata_to_binary()
  end

  defp single_annotation_xml(annot) do
    subtype = xfdf_subtype(annot.kind)
    page = annot.page_index
    rect = format_rect_attr(annot.rect)
    contents = xml_escape(to_string(annot.contents || ""))
    author = xml_escape(to_string(annot.author || ""))
    date = format_date(annot.inserted_at)
    color = format_color_attr(annot.color)

    attrs = [
      ~s[      page="#{page}"],
      ~s[      rect="#{rect}"]
    ]

    attrs = if color, do: attrs ++ [~s[      color="#{color}"]], else: attrs
    attrs = attrs ++ [~s[      date="#{date}"]]
    attrs = attrs ++ [~s[      title="#{author}">]]

    flags = annot.flags || %{}

    attrs =
      if Map.get(flags, "resolved", false) do
        attrs ++ [~s[      flags="print,resolved">]]
      else
        attrs
      end

    [
      ~s[    <#{subtype}\n],
      Enum.join(attrs, "\n"),
      ~s[\n      <contents>#{contents}</contents>],
      ~s[\n    </#{subtype}>]
    ]
    |> IO.iodata_to_binary()
  end

  defp reply_element(reply) do
    body = xml_escape(to_string(reply.body || ""))
    date = format_date(reply.inserted_at)

    ~s[      <reply-to>\n        <contents>#{body}</contents>\n        <date>#{date}</date>\n      </reply-to>]
  end

  # ── XFDF subtype mapping ────────────────────────────────────────────────

  @subtype_map %{
    "highlight" => "highlight",
    "underline" => "underline",
    "strikethrough" => "strikeout",
    "squiggly" => "squiggly",
    "sticky_note" => "text",
    "free_text" => "free-text",
    "free_text_callout" => "free-text",
    "ink" => "ink",
    "stamp" => "stamp",
    "signature" => "stamp",
    "line" => "line",
    "arrow" => "line",
    "double_arrow" => "line",
    "dimension" => "line",
    "oval" => "circle",
    "rectangle" => "square",
    "polygon" => "polygon",
    "cloud" => "polygon",
    "polyline" => "polyline",
    "file_attachment" => "fileattachment",
    "measure_distance" => "line",
    "measure_perimeter" => "polygon",
    "measure_area" => "polygon",
    "whiteout" => "square"
  }

  defp xfdf_subtype(kind), do: Map.get(@subtype_map, kind, "text")

  # ── Format helpers ─────────────────────────────────────────────────────

  defp format_rect_attr(nil), do: "0,0,0,0"

  defp format_rect_attr(%{"left" => l, "bottom" => b, "right" => r, "top" => t}),
    do: "#{l},#{b},#{r},#{t}"

  defp format_rect_attr(%{left: l, bottom: b, right: r, top: t}), do: "#{l},#{b},#{r},#{t}"

  defp format_rect_attr(rect) when is_map(rect) do
    ~w(left bottom right top)
    |> Enum.map(&Map.get(rect, &1, 0))
    |> Enum.join(",")
  end

  defp format_rect_attr(_), do: "0,0,0,0"

  defp format_color_attr(nil), do: nil
  defp format_color_attr(<<?#, r::2-bytes, g::2-bytes, b::2-bytes>>), do: "##{r}#{g}#{b}"

  defp format_color_attr(%{"r" => r, "g" => g, "b" => b}) when is_number(r),
    do: rgb_to_hex(r, g, b)

  defp format_color_attr(%{"r" => r, "g" => g, "b" => b}), do: "##{r}#{g}#{b}"
  defp format_color_attr(%{r: r, g: g, b: b}) when is_number(r), do: rgb_to_hex(r, g, b)
  defp format_color_attr(%{r: r, g: g, b: b}), do: "##{r}#{g}#{b}"
  defp format_color_attr(_), do: nil

  defp rgb_to_hex(r, g, b) do
    "##{hex_byte(round(r * 255))}#{hex_byte(round(g * 255))}#{hex_byte(round(b * 255))}"
  end

  defp hex_byte(val) when val < 16, do: "0" <> Integer.to_string(val, 16)
  defp hex_byte(val), do: Integer.to_string(val, 16)

  defp format_date(nil), do: "D:00000000000000"

  defp format_date(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("D:%Y%m%d%H%M%S'00'")
  end

  defp format_date(dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("D:%Y%m%d%H%M%S'00'")
  rescue
    _ -> "D:00000000000000"
  end

  defp xml_escape(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~S["], "&quot;")
    |> String.replace(~S['], "&apos;")
  end

  # ── XFDF import — Saxy handler ──────────────────────────────────────────

  defmodule XFDFHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    @annotation_tags ~w(highlight underline strikeout squiggly text free-text ink stamp line circle square polygon polyline fileattachment caret)

    def handle_event(:start_document, _prolog, state), do: {:ok, state}

    def handle_event(:start_element, {"annots", _attrs}, state), do: {:ok, state}

    def handle_event(:start_element, {name, attrs}, state) when name in @annotation_tags do
      annot = %{
        "type" => name,
        "page" => attr_int(attrs, "page", 0),
        "rect" => parse_rect(attr_str(attrs, "rect")),
        "color" => attr_str(attrs, "color"),
        "date" => attr_str(attrs, "date"),
        "title" => attr_str(attrs, "title", ""),
        "contents" => "",
        "flags" => attr_str(attrs, "flags", ""),
        "opacity" => attr_float(attrs, "opacity"),
        "replies" => []
      }

      {:ok, %{state | stack: [name | state.stack], current_annot: annot, text: ""}}
    end

    def handle_event(:start_element, {"contents", _attrs}, state) do
      {:ok, %{state | stack: ["contents" | state.stack], text: ""}}
    end

    def handle_event(:start_element, {"reply-to", _attrs}, state) do
      {:ok,
       %{state | stack: ["reply-to" | state.stack], current_reply: %{"body" => ""}, text: ""}}
    end

    def handle_event(:start_element, {"date", _attrs}, state) do
      {:ok, %{state | stack: ["date" | state.stack], text: ""}}
    end

    def handle_event(:start_element, {_name, _attrs}, state) do
      {:ok, %{state | stack: [nil | state.stack]}}
    end

    def handle_event(:characters, chars, %{text: text} = state) do
      {:ok, %{state | text: text <> chars}}
    end

    # ── End elements ─────────────────────────────────────────────────────

    def handle_event(:end_element, "annots", state), do: {:ok, state}
    def handle_event(:end_element, "xfdf", state), do: {:ok, state}

    def handle_event(:end_element, "contents", state) do
      annot = state.current_annot

      state =
        if annot do
          %{state | current_annot: %{annot | "contents" => state.text}}
        else
          state
        end

      {:ok, %{state | stack: tl(state.stack), text: ""}}
    end

    def handle_event(:end_element, "date", state) do
      reply = state.current_reply

      state =
        if reply do
          %{state | current_reply: Map.put(reply, "date", state.text)}
        else
          state
        end

      {:ok, %{state | stack: tl(state.stack), text: ""}}
    end

    def handle_event(:end_element, "reply-to", state) do
      reply = (state.current_reply || %{"body" => ""}) |> Map.put("body", state.text)
      annot = state.current_annot

      state =
        if annot do
          %{state | current_annot: %{annot | "replies" => annot["replies"] ++ [reply]}}
        else
          %{state | annots: state.annots ++ [reply |> Map.put("type", "reply")]}
        end

      {:ok, %{state | stack: tl(state.stack), current_reply: nil, text: ""}}
    end

    def handle_event(:end_element, name, state) when name in @annotation_tags do
      annot = state.current_annot

      state =
        if annot do
          %{
            state
            | annots: state.annots ++ [%{annot | "contents" => state.text}],
              current_annot: nil,
              text: ""
          }
        else
          state
        end

      {:ok, %{state | stack: tl(state.stack)}}
    end

    def handle_event(:end_element, _name, state) do
      {:ok, %{state | stack: tl(state.stack)}}
    end

    def handle_event(:end_document, _data, state), do: {:ok, state}

    # ── Attribute helpers ────────────────────────────────────────────────

    defp attr_str(attrs, key, default \\ nil) do
      case List.keyfind(attrs, key, 0) do
        {^key, val} -> val
        _ -> default
      end
    end

    defp attr_int(attrs, key, default) do
      case attr_str(attrs, key) do
        nil -> default
        s -> String.to_integer(s)
      end
    rescue
      _ -> default
    end

    defp attr_float(attrs, key) do
      case attr_str(attrs, key) do
        nil -> nil
        s -> elem(Float.parse(s), 0)
      end
    rescue
      _ -> nil
    end

    defp parse_rect(nil), do: %{"left" => 0, "bottom" => 0, "right" => 0, "top" => 0}

    defp parse_rect(s) when is_binary(s) do
      parts = String.split(s, ",")
      [l, b, r, t] = Enum.map(parts, &parse_float_safe/1)
      %{"left" => l, "bottom" => b, "right" => r, "top" => t}
    end

    defp parse_float_safe(s) do
      {f, _} = Float.parse(s)
      f
    rescue
      _ -> 0.0
    end
  end

  # ── Import database insertion ────────────────────────────────────────────

  defp insert_annotations(annots, document_id) do
    now = DateTime.utc_now()

    # Insert annotations with insert_all using raw table name to bypass the
    # schema/revision_id vs DB document_id mismatch.
    count =
      Enum.reduce(annots, 0, fn annot_data, cnt ->
        kind = import_kind(annot_data["type"])
        author = annot_data["title"] || ""
        rect = annot_data["rect"] || %{"left" => 0, "bottom" => 0, "right" => 0, "top" => 0}
        annot_id = Ecto.UUID.generate()

        Repo.insert_all("annotations", [
          %{
            id: annot_id,
            document_id: document_id,
            page_index: annot_data["page"] || 0,
            kind: kind,
            rect: rect,
            contents: annot_data["contents"] || "",
            author: author,
            color: annot_data["color"],
            opacity: annot_data["opacity"],
            flags: nil,
            replies_count: 0,
            inserted_at: now,
            updated_at: now
          }
        ])

        replies = annot_data["replies"] || []

        Enum.each(replies, fn reply_data ->
          reply_id = Ecto.UUID.generate()

          Repo.insert_all({"annotation_replies", Quire.Documents.AnnotationReply}, [
            %{
              id: reply_id,
              annotation_id: annot_id,
              user_id: "00000000-0000-0000-0000-000000000000",
              body: reply_data["body"] || "",
              inserted_at: now
            }
          ])
        end)

        cnt + 1
      end)

    count
  end

  @import_kind_map %{
    "highlight" => "highlight",
    "underline" => "underline",
    "strikeout" => "strikethrough",
    "squiggly" => "squiggly",
    "text" => "sticky_note",
    "free-text" => "free_text",
    "ink" => "ink",
    "stamp" => "stamp",
    "line" => "line",
    "circle" => "oval",
    "square" => "rectangle",
    "polygon" => "polygon",
    "polyline" => "polyline",
    "fileattachment" => "file_attachment",
    "caret" => "sticky_note"
  }

  defp import_kind(xfdf_type), do: Map.get(@import_kind_map, xfdf_type, "sticky_note")
end
