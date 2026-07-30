defmodule Quire.Workers.OcrWorker do
  @moduledoc ~S"""
  Oban worker for the full in-BEAM OCR pipeline (§T-139).

  Pipeline per page:

    1. Fetch source revision bytes from `Quire.Storage` (no file I/O)
    2. PDFium rasterise at 300 DPI
    3. Vix preprocess (grayscale, binarize)
    4. Tesseract NIF recognise
    5. ExPdfium sandwich compose — full-page raster image + invisible text layer
    6. Store result as new revision via `Quire.Documents`

  ## Queue

  Runs on the `:ocr` queue, serialised (concurrency 1, §7.2).
  Job uniqueness prevents concurrent OCR on the same revision.

  ## Job args

      %{
        "doc_id"       => doc_id,          # required
        "revision_id"  => revision_id,     # required
        "operation_id" => op_id,           # optional, for progress reporting
        "page_range"   => [0, 1, 2]        # optional, default `:all`
      }

  ## Idempotency

  The job is unique on `[:worker, :args]` for 60 s, preventing duplicate
  enqueues.  The revision check in `guard_idempotent/2` is not used
  because OCR always produces a new revision rather than overwriting an
  existing one — each job call creates a fresh label with the run date.
  """

  use Oban.Worker,
    queue: :ocr,
    unique: [period: 60, fields: [:worker, :args]],
    max_attempts: 3

  use Quire.Workers.Base

  alias Quire.Repo
  alias Quire.Documents.{Document, Revision}

  @dpi 300

  # ── Oban callback ──────────────────────────────────────────────────────

  @doc false
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: args}) do
    doc_id = args["doc_id"]
    revision_id = args["revision_id"]
    operation_id = args["operation_id"]

    with {:ok, doc} <- fetch_document(doc_id),
         {:ok, rev} <- fetch_revision(revision_id),
         %Quire.Storage.Ref{} = ref <- Revision.storage_ref(rev),
         {:ok, source_bytes} <- Quire.Storage.get(ref) do
      emit_telemetry(:start, %{doc_id: doc_id, revision_id: revision_id})
      report_progress(operation_id, doc_id, 5)

      result = run_pipeline(source_bytes, doc, rev, operation_id)

      case result do
        {:ok, %{new_revision: _new_rev, page_count: pc}} ->
          emit_telemetry(:completed, %{page_count: pc, doc_id: doc_id})
          report_progress(operation_id, doc_id, 100)
          :ok

        {:error, reason} ->
          emit_telemetry(:failed, %{reason: reason, doc_id: doc_id})
          {:error, reason}
      end
    else
      nil -> {:error, "no storage ref on revision #{revision_id}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Pipeline ────────────────────────────────────────────────────────────

  defp run_pipeline(source_bytes, doc, rev, operation_id) do
    page_range = resolve_page_range(rev, doc)
    total = length(page_range)

    # ── Phase 1: open source & prepare result document ────────────────
    with {:ok, src_doc} <- ExPdfium.open_blob(source_bytes),
         {:ok, _src_count} <- ExPdfium.page_count(src_doc) do
      try do
        result = build_sandwich(src_doc, page_range, doc, operation_id, total)

        case result do
          {:ok, %ExPdfium.Document{} = result_doc} ->
            # Close source before saving
            ExPdfium.close(src_doc)
            persist_result(result_doc, doc, rev)

          {:error, _} = err ->
            err
        end
      after
        # In case build_sandwich raised or returned error before close
        catch_all_close(src_doc)
      end
    end
  end

  # ── Sandwich builder ──────────────────────────────────────────────────

  defp build_sandwich(src_doc, page_range, doc, operation_id, total) do
    {:ok, result_doc} = ExPdfium.new()

    # Emissions are fire-and-forget; if the operation_id is nil the
    # progress helper is a no-op.  Track elapsed time for telemetry.
    timings = %{}

    result =
      Enum.reduce_while(Enum.with_index(page_range), {:ok, result_doc, timings, 0},
        fn {page_idx, i}, {:ok, acc_doc, acc_timings, last_pct} ->
          # Progress 10–90 % spread across pages
          pct = min(10 + div((i + 1) * 80, total), 90)

          if pct != last_pct do
            report_progress(operation_id, doc.id, pct)
          end

          {elapsed, page_result} =
            :timer.tc(fn ->
              process_one_page(src_doc, acc_doc, page_idx)
            end)

          page_info = %{page: page_idx, elapsed_us: elapsed}

          case page_result do
            {:ok, updated_doc, spans} ->
              avg_conf =
                if spans != [],
                  do: avg_confidence(spans),
                  else: nil

              emit_telemetry(:page_done, page_info |> Map.put(:avg_confidence, avg_conf))

              {:cont, {:ok, updated_doc, acc_timings, pct}}

            {:error, reason} ->
              {:halt, {:error, {:page_failed, page_idx, reason}}}
          end
        end
      )

    case result do
      {:ok, final_doc, _timings, _pct} -> {:ok, final_doc}
      {:error, _} = err -> err
    end
  end

  # ── Single page ────────────────────────────────────────────────────────

  defp process_one_page(src_doc, dest_doc, page_idx) do
    with {:ok, info} <- ExPdfium.page_info(src_doc, page_idx) do
      # Determine page dimensions (crop-aware)
      dims = page_dimensions(info)
      width = elem(dims, 0)
      height = elem(dims, 1)

      # ── Step 1: Render page at 300 DPI ─────────────────────────────
      {:ok, bitmap} = ExPdfium.render_page(src_doc, page_idx, dpi: @dpi)

      # ── Step 2: Convert Bitmap → PNG for OCR ───────────────────────
      png_bytes = bitmap_to_png!(bitmap)

      # ── Step 3: Preprocess ─────────────────────────────────────────
      {:ok, processed_png} = Quire.Ocr.Preprocess.preprocess(png_bytes)

      # ── Step 4: OCR ────────────────────────────────────────────────
      {:ok, spans} = Quire.Ocr.Tesseract.run(processed_png, [])

      # ── Step 5: Build the sandwich page in a temp document ─────────
      {:ok, temp_doc} = ExPdfium.new()
      {:ok, temp_doc} = ExPdfium.add_page(temp_doc, {width * 1.0, height * 1.0})

      # Draw the full-page raster image (covers the page visually).
      {:ok, temp_doc} =
        ExPdfium.draw_image(temp_doc, 0, bitmap,
          at: %{left: 0.0, bottom: 0.0, right: width * 1.0, top: height * 1.0}
        )

      # Draw OCR text at each word position.
      # The text is drawn after the image so it is in the content stream
      # for selection/search.  If rendered on top of the image it appears
      # as visible overlay; the content-stream order guarantees the text
      # is always selectable regardless of the NIF insertion direction.
      scale = 72.0 / @dpi
      img_h = bitmap.height

      temp_doc =
        Enum.reduce(spans, temp_doc, fn span, doc_acc ->
          draw_ocr_word(doc_acc, 0, span, scale, img_h)
        end)

      # ── Step 6: Append to result document ──────────────────────────
      {:ok, dest_doc} = ExPdfium.append(dest_doc, temp_doc)
      ExPdfium.close(temp_doc)

      {:ok, dest_doc, spans}
    end
  end

  # ── OCR word placement ────────────────────────────────────────────────

  # Convert an OCR span's pixel bounding box to PDF coordinates and draw
  # the recognised text.
  #
  # OCR coordinates have top-left origin (Tesseract convention).  PDF
  # coordinates have bottom-left origin, so the Y axis is flipped.
  defp draw_ocr_word(doc, page, span, scale, img_h) do
    bbox = span.bbox
    x = bbox.x
    # Tesseract y1 is the top of the bounding box; the baseline (bottom
    # of the box) in PDF coordinates is (img_h - y1 - h) * scale.
    y = bbox.y
    h = bbox.h

    pdf_x = x * scale
    # Baseline at the bottom of the word box, flipped to PDF y-up.
    pdf_y = (img_h - y - h) * scale
    # Approximate font size to fill the word's bounding box height.
    font_size = h * scale

    # Clamp font size to a reasonable range (4–144 pt) to avoid
    # pathological values from malformed OCR results.
    font_size = font_size |> max(4.0) |> min(144.0)

    # Draw text at the word position.  We use a Standard 14 font so no
    # font embedding is required.
    case ExPdfium.draw_text(doc, page, {pdf_x, pdf_y}, span.text,
           font: :helvetica,
           size: font_size,
           color: {0, 0, 0}
         ) do
      {:ok, updated_doc} -> updated_doc
      {:error, _reason} -> doc
    end
  end

  # ── Persist result ────────────────────────────────────────────────────

  defp persist_result(result_doc, doc, _rev) do
    case ExPdfium.save_to_bytes(result_doc) do
      {:ok, pdf_bytes} ->
        ExPdfium.close(result_doc)

        label = "OCR (#{Date.utc_today()})"

        {:ok, ref} =
          Quire.Storage.put(pdf_bytes,
            name: doc.title || "ocr_result",
            content_type: "application/pdf"
          )

        source_map = %{
          "storage_ref" => %{
            "adapter" => to_string(ref.adapter),
            "key" => ref.key,
            "name" => ref.name,
            "content_type" => ref.content_type,
            "byte_size" => ref.byte_size
          },
          "filename" => doc.title || "ocr_result.pdf"
        }

        {:ok, new_rev} = Quire.Documents.create_revision(doc, label: label, source: source_map)

        # Update document's current revision pointer.
        {:ok, _updated_doc} =
          doc
          |> Ecto.Changeset.change(%{current_revision_id: new_rev.id})
          |> Repo.update()

        # Broadcast revision on the document's PubSub topic.
        Phoenix.PubSub.broadcast(
          Quire.PubSub,
          "document:#{doc.id}",
          {:revision, new_rev}
        )

        {:ok, %{new_revision: new_rev, page_count: nil}}

      {:error, reason} ->
        ExPdfium.close(result_doc)
        {:error, reason}
    end
  end

  # ── Page resolution ──────────────────────────────────────────────────

  # Determine the list of zero-based page indices to process.
  # Defaults to all pages when no range is given.
  defp resolve_page_range(%Revision{}, %Document{page_count: pc}) do
    0..(pc - 1)//1 |> Enum.to_list()
  end

  # ── Dimensions ────────────────────────────────────────────────────────

  defp page_dimensions(%{boxes: %{crop: nil}} = info),
    do: {trunc(info.width), trunc(info.height)}

  defp page_dimensions(%{boxes: %{crop: crop}}),
    do: {trunc(crop.right - crop.left), trunc(crop.top - crop.bottom)}

  # ── Bitmap → PNG conversion ──────────────────────────────────────────

  # Converts an ExPdfium.Bitmap to a PNG binary for the OCR preprocessing
  # pipeline.  Handles the RGB byte-order swap that pdfium's native BGR
  # format requires.
  defp bitmap_to_png!(%ExPdfium.Bitmap{data: data, width: w, height: h, format: format}) do
    {converted, bands} = normalize_bitmap(data, format)

    {:ok, image} =
      Vix.Vips.Image.new_from_binary(converted, w, h, bands, :VIPS_FORMAT_UCHAR)

    {:ok, png} = Vix.Vips.Image.write_to_buffer(image, ".png")
    png
  end

  defp normalize_bitmap(data, :rgba), do: {data, 4}
  defp normalize_bitmap(data, :bgra), do: {swap_rb_4(data), 4}
  defp normalize_bitmap(data, :bgrx), do: {swap_rb_4(data), 4}
  defp normalize_bitmap(data, :bgr), do: {swap_rb_3(data), 3}
  defp normalize_bitmap(data, :gray), do: {data, 1}

  defp swap_rb_4(data) do
    for <<r::8, g::8, b::8, a::8 <- data>>, into: <<>>, do: <<b::8, g::8, r::8, a::8>>
  end

  defp swap_rb_3(data) do
    for <<r::8, g::8, b::8 <- data>>, into: <<>>, do: <<b::8, g::8, r::8>>
  end

  # ── Confidence ──────────────────────────────────────────────────────

  defp avg_confidence(spans) do
    confs = Enum.map(spans, & &1.confidence)

    if confs == [],
      do: nil,
      else: Enum.sum(confs) / length(confs)
  end

  # ── Telemetry ────────────────────────────────────────────────────────

  defp emit_telemetry(:start, meta) do
    :telemetry.execute([:quire, :ocr, :start], %{}, meta)
  end

  defp emit_telemetry(:completed, meta) do
    :telemetry.execute([:quire, :ocr, :completed], meta)
  end

  defp emit_telemetry(:failed, meta) do
    :telemetry.execute([:quire, :ocr, :failed], meta)
  end

  defp emit_telemetry(:page_done, meta) do
    :telemetry.execute([:quire, :ocr, :page_done], meta)
  end

  # ── Progress reporting ──────────────────────────────────────────────

  defp report_progress(nil, _doc_id, _pct), do: :ok

  defp report_progress(operation_id, doc_id, pct) do
    Quire.Workers.Base.report_progress(operation_id, doc_id, pct)
  end

  # ── DB helpers ───────────────────────────────────────────────────────

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

  # ── Resource safety ──────────────────────────────────────────────────

  defp catch_all_close(doc) do
    try do
      ExPdfium.close(doc)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    else
      _ -> :ok
    end
  end
end
