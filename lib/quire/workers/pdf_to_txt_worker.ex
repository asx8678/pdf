defmodule Quire.Workers.PdfToTxtWorker do
  @moduledoc ~S"""
  Oban worker for PDF-to-plain-text conversion in two modes (§T-076).

  ## Modes

    * `"layout"` — positions text using span bounding boxes to preserve
      column geometry.  Multi-column fixtures keep their column layout
      with space‑separated columns.
    * `"reading_order"` — concatenates span text in PDFium's extraction
      order, producing a single linear stream.  Multi-column fixtures
      are linearised (different output from layout mode).

  ## Queue

  Runs on the `:convert` queue, serialised (concurrency 1, §7.2).

  ## Job args

      %{
        "doc_id"       => doc_id,          # required
        "revision_id"  => revision_id,     # required
        "mode"         => "layout" | "reading_order",  # required
        "operation_id" => op_id            # optional, for progress
      }

  ## Output

  The extracted text is stored as a `.txt` blob through `Quire.Storage`
  and a new revision is created referencing it.
  """

  use Oban.Worker,
    queue: :convert,
    unique: [period: 60, fields: [:worker, :args]],
    max_attempts: 2

  use Quire.Workers.Base

  alias Quire.Repo
  alias Quire.Storage
  alias Quire.Documents
  alias Quire.Documents.{Document, Revision}

  # Character width in PDF points used for layout‑mode positioning.
  # 8 pt per character approximates a 12‑pt monospace glyph advance.
  @char_width 8.0
  @space_width 4.0

  # ── Oban callback ──────────────────────────────────────────────────────

  @doc false
  @impl true
  def perform(%Oban.Job{args: args}) do
    doc_id = args["doc_id"]
    revision_id = args["revision_id"]
    mode = args["mode"] || "reading_order"
    operation_id = args["operation_id"]

    with {:ok, _doc} <- fetch_document(doc_id),
         {:ok, rev} <- fetch_revision(revision_id),
         %Storage.Ref{} = ref <- Revision.storage_ref(rev) do
      report_progress(operation_id, doc_id, 5)

      case build_text(ref, mode, operation_id, doc_id) do
        {:ok, text} ->
          persist_result(text, args)
          report_progress(operation_id, doc_id, 100)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, "no storage ref on revision #{revision_id}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Text extraction ─────────────────────────────────────────────────────

  defp build_text(ref, mode, operation_id, doc_id) do
    with {:ok, page_results} <- Quire.Render.extract_text(ref, []) do
      total = length(page_results)

      lines =
        page_results
        |> Enum.with_index()
        |> Enum.map(fn {%{page: _page_idx, spans: spans}, i} ->
          pct = min(10 + div((i + 1) * 85, total), 95)
          report_progress(operation_id, doc_id, pct)

          case mode do
            "layout" -> layout_page(spans || [])
            "reading_order" -> reading_order_page(spans || [])
            _ -> reading_order_page(spans || [])
          end
        end)

      {:ok, Enum.join(lines, "\n")}
    end
  end

  # ── Layout mode ─────────────────────────────────────────────────────────

  # Layout mode sorts spans visually (top‑to‑bottom, left‑to‑right) and
  # positions text with spaces to preserve column geometry.

  defp layout_page(spans) do
    spans
    |> Enum.filter(& &1.bounds)
    |> Enum.sort_by(fn s -> {-(s.bounds.top + s.bounds.bottom), s.bounds.left} end)
    |> group_into_lines()
    |> Enum.map_join("\n", &render_line/1)
  end

  # Group spans into lines when their vertical ranges overlap within a
  # threshold.  The threshold is half the average line height.
  defp group_into_lines([]), do: []

  defp group_into_lines([first | rest]) do
    avg_height = avg_line_height([first | rest])
    threshold = max(avg_height * 0.5, 4.0)
    do_group_lines(rest, [[first]], threshold)
  end

  defp do_group_lines([], groups, _threshold), do: Enum.map(groups, &Enum.reverse/1)

  defp do_group_lines([span | rest], [current | groups], threshold) do
    ref_span = hd(current)
    overlap_y = y_overlap(ref_span, span)

    if overlap_y >= threshold do
      do_group_lines(rest, [[span | current] | groups], threshold)
    else
      do_group_lines(rest, [[span], current | groups], threshold)
    end
  end

  defp y_overlap(a, b) do
    a_top = max(a.bounds.top, b.bounds.top)
    a_bot = min(a.bounds.bottom, b.bounds.bottom)
    max(0.0, a_top - a_bot)
  end

  defp avg_line_height(spans) do
    heights =
      Enum.map(spans, fn s ->
        abs(s.bounds.top - s.bounds.bottom)
      end)

    if heights == [],
      do: 12.0,
      else: Enum.sum(heights) / length(heights)
  end

  # Render a line of spans as text positioned with spaces.
  defp render_line([]), do: ""

  defp render_line(spans) do
    sorted = Enum.sort_by(spans, & &1.bounds.left)
    # Calculate indent from the first span's left edge relative to page min
    min_left = Enum.map(sorted, & &1.bounds.left) |> Enum.min()
    indent_chars = max(0, round((hd(sorted).bounds.left - min_left) / @char_width))
    indent = String.duplicate(" ", indent_chars)

    body =
      sorted
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] ->
        gap = max(0, b.bounds.left - a.bounds.right)
        spaces = max(1, round(gap / @space_width))
        a.text <> String.duplicate(" ", spaces)
      end)
      |> then(fn parts ->
        parts ++ [List.last(sorted).text]
      end)
      |> IO.iodata_to_binary()

    indent <> body
  end

  # ── Reading‑order mode ──────────────────────────────────────────────────

  # Reading‑order mode concatenates span text in the order PDFium returned
  # it, which follows the logical reading order of the document.

  defp reading_order_page(spans) do
    spans
    |> Enum.map(fn s -> s.text end)
    |> Enum.join("")
  end

  # ── Persistence ─────────────────────────────────────────────────────────

  defp persist_result(text, args) do
    doc_id = args["doc_id"]
    filename = "extracted.txt"
    label = "Text extract (#{Date.utc_today()})"
    doc = Repo.get(Document, doc_id)

    if is_nil(doc) do
      emit_telemetry(:persist_failed, %{doc_id: doc_id, error: :not_found})
    else
      case Storage.put(text, name: filename, content_type: "text/plain") do
        {:ok, ref} ->
          source_map = %{
            "storage_ref" => %{
              "adapter" => to_string(ref.adapter),
              "key" => ref.key,
              "name" => ref.name,
              "content_type" => ref.content_type,
              "byte_size" => ref.byte_size
            },
            "filename" => filename
          }

          {:ok, _rev} = Documents.create_revision(doc, label: label, source: source_map)
          emit_telemetry(:persisted, %{doc_id: doc_id, revision_label: label})

        {:error, reason} ->
          emit_telemetry(:persist_failed, %{doc_id: doc_id, error: inspect(reason)})
      end
    end
  end

  # ── Progress reporting ──────────────────────────────────────────────────

  defp report_progress(nil, _doc_id, _pct), do: :ok

  defp report_progress(operation_id, doc_id, pct) do
    Quire.Workers.Base.report_progress(operation_id, doc_id, pct)
  end

  # ── Telemetry ─────────────────────────────────────────────────────────

  defp emit_telemetry(event, metadata) do
    :telemetry.execute([:quire, :txt_extract, event], %{duration: nil}, metadata)
  rescue
    _ -> :ok
  end

  # ── DB helpers ─────────────────────────────────────────────────────────

  defp fetch_document(doc_id) do
    case Repo.get(Document, doc_id) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  defp fetch_revision(revision_id) do
    case Repo.get(Revision, revision_id) do
      nil -> {:error, :not_found}
      rev -> {:ok, rev}
    end
  end
end
