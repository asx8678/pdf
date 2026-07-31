defmodule Quire.Workers.PdfToRtfWorker do
  @moduledoc ~S"""
  Oban worker for PDF-to-RTF conversion (§T-076).

  Extracts text from PDF via `Render.extract_text/2`, builds a
  `Quire.Office.Layout.t()` from the extracted spans, and renders it
  through `Quire.Office.Writer.Rtf`.

  ## Pipeline

    1. Fetch source revision bytes from `Quire.Storage`
    2. `Render.extract_text/2` — per‑page spans with bounds
    3. Build `Quire.Office.Layout` (page → section, line → paragraph)
    4. `Office.Writer.Rtf.write/3` → RTF string
    5. Store `.rtf` blob and create revision

  ## Queue

  Runs on the `:convert` queue, serialised (concurrency 1, §7.2).

  ## Job args

      %{
        "doc_id"       => doc_id,          # required
        "revision_id"  => revision_id,     # required
        "operation_id" => op_id            # optional, for progress
      }

  ## Output

  The RTF document is stored as a `.rtf` blob through `Quire.Storage`
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
  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section

  # ── Oban callback ──────────────────────────────────────────────────────

  @doc false
  @impl true
  def perform(%Oban.Job{args: args}) do
    doc_id = args["doc_id"]
    revision_id = args["revision_id"]
    operation_id = args["operation_id"]

    with {:ok, _doc} <- fetch_document(doc_id),
         {:ok, rev} <- fetch_revision(revision_id),
         %Storage.Ref{} = ref <- Revision.storage_ref(rev) do
      report_progress(operation_id, doc_id, 5)

      case build_rtf(ref, operation_id, doc_id) do
        {:ok, rtf} ->
          persist_result(rtf, args)
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

  # ── RTF build ───────────────────────────────────────────────────────────

  defp build_rtf(ref, operation_id, doc_id) do
    with {:ok, page_results} <- Quire.Render.extract_text(ref, []) do
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

      Quire.Office.Writer.Rtf.write(layout, :rtf)
    end
  end

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

  defp persist_result(rtf, args) do
    doc_id = args["doc_id"]
    filename = "extracted.rtf"
    label = "RTF extract (#{Date.utc_today()})"
    doc = Repo.get(Document, doc_id)

    if is_nil(doc) do
      emit_telemetry(:persist_failed, %{doc_id: doc_id, error: :not_found})
    else
      case Storage.put(rtf, name: filename, content_type: "application/rtf") do
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

          {:ok, new_rev} = Documents.create_revision(doc, label: label, source: source_map)
          broadcast_revision(doc, new_rev)
          emit_telemetry(:persisted, %{doc_id: doc_id, revision_label: label})

        {:error, reason} ->
          emit_telemetry(:persist_failed, %{doc_id: doc_id, error: inspect(reason)})
      end
    end
  end

  defp broadcast_revision(doc, new_rev) do
    # Update the document's current_revision pointer and notify the workspace
    # so the UI clears its "converting" state and the viewer reloads (Gate 4).
    doc
    |> Ecto.Changeset.change(%{current_revision_id: new_rev.id})
    |> Repo.update()

    Phoenix.PubSub.broadcast(Quire.PubSub, "document:#{doc.id}", {:revision, new_rev})
  end

  # ── Progress reporting ──────────────────────────────────────────────────

  defp report_progress(nil, _doc_id, _pct), do: :ok

  defp report_progress(operation_id, doc_id, pct) do
    Quire.Workers.Base.report_progress(operation_id, doc_id, pct)
  end

  # ── Telemetry ─────────────────────────────────────────────────────────

  defp emit_telemetry(event, metadata) do
    :telemetry.execute([:quire, :rtf_extract, event], %{duration: nil}, metadata)
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
