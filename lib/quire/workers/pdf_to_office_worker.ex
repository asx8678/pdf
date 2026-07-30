defmodule Quire.Workers.PdfToOfficeWorker do
  @moduledoc ~S"""
  Oban worker for PDF-to-Office-format conversion (DOCX, XLSX, PPTX).

  Extracts text from PDF via `Render.extract_text/2`, builds a
  `Quire.Office.Layout.t()` from the extracted spans, and renders it
  through the appropriate `Quire.Office.Writer` module.

  ## Pipeline

    1. Fetch source revision bytes from `Quire.Storage`
    2. `Render.extract_text/2` — per‑page spans with bounds
    3. Check for empty text layer → OCR prompt if empty
    4. Build `Quire.Office.Layout` (page → section, line → paragraph)
    5. `Office.Writer.<Format>.write/3` → OOXML binary
    6. Store blob and create revision

  ## Queue

  Runs on the `:convert` queue, serialised (concurrency 1, §7.2).

  ## Job args

      %{
        "doc_id"       => doc_id,          # required
        "revision_id"  => revision_id,     # required
        "format"       => "docx"|"xlsx"|"pptx",  # required
        "operation_id" => op_id            # optional, for progress
      }

  ## Output

  The Office document is stored as a `.docx`/`.xlsx`/`.pptx` blob through
  `Quire.Storage` and a new revision is created referencing it.
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
  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  @format_ext %{
    "docx" => ".docx",
    "xlsx" => ".xlsx",
    "pptx" => ".pptx"
  }

  @format_content_type %{
    "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  }

  # ── Oban callback ──────────────────────────────────────────────────────

  @doc false
  @impl true
  def perform(%Oban.Job{args: args}) do
    doc_id = args["doc_id"]
    revision_id = args["revision_id"]
    format = args["format"]
    operation_id = args["operation_id"]

    with {:ok, _doc} <- fetch_document(doc_id),
         {:ok, rev} <- fetch_revision(revision_id),
         %Storage.Ref{} = ref <- Revision.storage_ref(rev) do
      report_progress(operation_id, doc_id, 5)

      case build_office(ref, format, operation_id, doc_id) do
        {:ok, office_binary} ->
          persist_result(office_binary, args)
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

  # ── Office document build ──────────────────────────────────────────────

  defp build_office(ref, format, operation_id, doc_id) do
    with {:ok, page_results} <- Quire.Render.extract_text(ref, []) do
      # Check for empty text layer
      has_text =
        page_results
        |> Enum.any?(fn %{spans: spans} ->
          spans && spans != [] &&
            Enum.any?(spans, fn s -> s.text && String.trim(s.text) != "" end)
        end)

      unless has_text do
        {:error, "This PDF has no text layer. Run OCR first, then try again."}
      else
        total = length(page_results)

        layout =
          page_results
          |> Enum.with_index()
          |> Enum.reduce(Layout.new(), fn {%{spans: spans}, i}, acc ->
            pct = min(10 + div((i + 1) * 85, total), 95)
            report_progress(operation_id, doc_id, pct)

            section = spans_to_section(spans || [])
            %{acc | sections: acc.sections ++ [section]}
          end)

        writer = writer_for_format(format)

        case writer do
          nil -> {:error, "Unsupported format: #{format}"}
          _ -> writer.write(layout, String.to_atom(format), [])
        end
      end
    end
  end

  # ── Writer dispatch ────────────────────────────────────────────────────

  defp writer_for_format("docx"), do: Quire.Office.Writer.Docx
  defp writer_for_format("xlsx"), do: Quire.Office.Writer.Xlsx
  defp writer_for_format("pptx"), do: Quire.Office.Writer.Pptx
  defp writer_for_format(_), do: nil

  # ── Spans → Layout section ─────────────────────────────────────────────

  # Group spans on a page into visual lines, then emit each line as a
  # paragraph block.

  defp spans_to_section(spans) do
    block_spans = Enum.filter(spans, & &1.bounds)

    paragraphs =
      block_spans
      |> Enum.sort_by(fn s -> {-(s.bounds.top + s.bounds.bottom), s.bounds.left} end)
      |> group_into_lines()
      |> Enum.map(fn line ->
        text =
          line
          |> Enum.sort_by(& &1.bounds.left)
          |> Enum.map(fn s -> s.text end)
          |> Enum.join(" ")

        {:paragraph, text}
      end)

    %Section{type: :page, title: nil, blocks: paragraphs}
  end

  # ── Line grouping ───────────────────────────────────────────────────────

  # Group spans into lines when their vertical ranges overlap within a
  # threshold (half the average line height).

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

  # ── Persistence ─────────────────────────────────────────────────────────

  defp persist_result(office_binary, args) do
    doc_id = args["doc_id"]
    format = args["format"]
    ext = Map.get(@format_ext, format, ".bin")
    content_type = Map.get(@format_content_type, format, "application/octet-stream")
    filename = "extracted#{ext}"
    label = "#{String.upcase(format)} extract (#{Date.utc_today()})"
    doc = Repo.get(Document, doc_id)

    if is_nil(doc) do
      emit_telemetry(:persist_failed, %{doc_id: doc_id, error: :not_found})
    else
      case Storage.put(office_binary, name: filename, content_type: content_type) do
        {:ok, ref} ->
          source_map = %{
            "storage_ref" => %{
              "adapter" => to_string(ref.adapter),
              "key" => ref.key,
              "name" => ref.name,
              "content_type" => ref.content_type,
              "byte_size" => ref.byte_size
            },
            "filename" => filename,
            "format" => format,
            "note" => "Best for text-based PDFs. Formatting fidelity is best-effort."
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
    :telemetry.execute([:quire, :office_extract, event], %{duration: nil}, metadata)
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
