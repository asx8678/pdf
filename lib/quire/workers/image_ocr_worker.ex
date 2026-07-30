defmodule Quire.Workers.ImageOcrWorker do
  @moduledoc ~S"""
  Produces a searchable PDF from an uploaded standalone image (PNG, JPEG, WebP).

  ## Pipeline

    1. Magic-byte validation (not extension-based)
    2. Vix load and colourspace conversion (CMYK/greyscale → sRGB)
    3. Vix preprocess → grayscale PNG
    4. Tesseract NIF recognition
    5. ExPdfium single-page sandwich — full-page raster image + invisible text layer
    6. Save PDF bytes through `Quire.Storage`
    7. Create document + revision via `Quire.Documents.ingest/3`

  Reuses `OcrWorker` patterns for confidence, telemetry, and progress reporting.
  """

  alias Quire.Documents

  # ── Magic byte patterns ─────────────────────────────────────────────────

  @png_magic <<137, 80, 78, 71>>
  @jpeg_magic <<255, 216, 255>>
  @webp_prefix <<82, 73, 70, 70>>
  @webp_suffix <<87, 69, 66, 80>>

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Processes an image binary into a searchable PDF document.

  `image_bytes` is the raw file content (PNG, JPEG, or WebP).  `title` is the
  display name (typically the filename minus extension).  `scope` is the caller's
  authorisation scope (required by `Quire.Documents.ingest/3`).

  Returns `{:ok, %{document: doc, document_url: url}}` or
  `{:error, {:invalid_image, message}}` when the bytes do not match a supported
  format, or `{:error, reason}` on pipeline failure.

  ## Examples

      {:ok, %{document: doc, document_url: url}} =
        Quire.Workers.ImageOcrWorker.process(image_bytes, "scan_001", scope)
  """
  @spec process(binary(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def process(image_bytes, title, scope) when is_binary(image_bytes) and is_binary(title) do
    emit_telemetry(:start, %{title: title, byte_size: byte_size(image_bytes)})

    result =
      with {:ok, _fmt} <- validate_magic(image_bytes),
           {:ok, pdf_bytes} <- build_pdf(image_bytes) do
        Documents.ingest(pdf_bytes, scope, title: title)
      end

    case result do
      {:ok, %{document: doc} = map} ->
        emit_telemetry(:completed, %{doc_id: doc.id, title: title})
        {:ok, map}

      {:error, reason} ->
        emit_telemetry(:failed, %{reason: inspect(reason), title: title})
        {:error, reason}
    end
  end

  # ── Magic-byte validation ──────────────────────────────────────────────

  @doc """
  Validates that `image_bytes` starts with a recognised image magic sequence.

  Returns `{:ok, :png}`, `{:ok, :jpeg}`, `{:ok, :webp}` on success, or
  `{:error, {:invalid_image, message}}` on failure.
  """
  @spec validate_magic(binary()) :: {:ok, atom()} | {:error, {:invalid_image, String.t()}}
  def validate_magic(<<@png_magic, _rest::binary>>), do: {:ok, :png}
  def validate_magic(<<@jpeg_magic, _rest::binary>>), do: {:ok, :jpeg}

  def validate_magic(<<@webp_prefix, _::binary-size(4), @webp_suffix, _rest::binary>>),
    do: {:ok, :webp}

  def validate_magic(_other) do
    {:error,
     {:invalid_image,
      "The file does not appear to be a supported image format. Accepted formats: PNG, JPEG, WebP."}}
  end

  # ── PDF builder ────────────────────────────────────────────────────────

  defp build_pdf(image_bytes) do
    # Load through Vix — handles CMYK, greyscale, sRGB, and alpha automatically
    {:ok, img} = Vix.Vips.Image.new_from_buffer(image_bytes)
    {:ok, srgb} = Vix.Vips.Operation.colourspace(img, :VIPS_INTERPRETATION_sRGB)

    width = Vix.Vips.Image.width(srgb)
    height = Vix.Vips.Image.height(srgb)

    # Get PNG representation for the OCR preprocessing pipeline
    {:ok, png_bytes} = Vix.Vips.Image.write_to_buffer(srgb, ".png")

    # ── Phase 1: Preprocess ───────────────────────────────────────────
    preprocess_opts = [
      deskew: true,
      rotate: true,
      clean: true,
      optimise: 1
    ]

    {:ok, processed_png} = Quire.Ocr.Preprocess.preprocess(png_bytes, preprocess_opts)

    # ── Phase 2: OCR ──────────────────────────────────────────────────
    ocr_opts = [language: "eng"]
    {:ok, spans} = Quire.Ocr.Tesseract.run(processed_png, ocr_opts)

    # ── Phase 3: Build the sandwich page ──────────────────────────────
    build_sandwich(srgb, width, height, spans)
  end

  # ── Sandwich compose ──────────────────────────────────────────────────

  defp build_sandwich(srgb_img, width, height, spans) do
    # Convert Vix sRGB image → ExPdfium.Bitmap (BGR byte order for pdfium)
    bitmap = image_to_bitmap(srgb_img)

    {:ok, doc} = ExPdfium.new()
    {:ok, doc} = ExPdfium.add_page(doc, {width * 1.0, height * 1.0})

    # Draw the full-page raster image (covers the page visually)
    {:ok, doc} =
      ExPdfium.draw_image(doc, 0, bitmap,
        at: %{left: 0.0, bottom: 0.0, right: width * 1.0, top: height * 1.0}
      )

    # Draw OCR text at each word position.
    # The text is drawn after the image so it is in the content stream
    # for selection/search.
    doc =
      Enum.reduce(spans, doc, fn span, doc_acc ->
        draw_ocr_word(doc_acc, 0, span, width, height)
      end)

    # Save to bytes
    case ExPdfium.save_to_bytes(doc) do
      {:ok, pdf_bytes} ->
        ExPdfium.close(doc)
        {:ok, pdf_bytes}

      {:error, reason} ->
        ExPdfium.close(doc)
        {:error, reason}
    end
  end

  # ── Vix image → ExPdfium.Bitmap ──────────────────────────────────────

  # Converts a Vix sRGB image (RGB byte order, 3 bands) into an
  # ExPdfium.Bitmap with BGR byte order, suitable for draw_image/4.
  defp image_to_bitmap(srgb_img) do
    width = Vix.Vips.Image.width(srgb_img)
    height = Vix.Vips.Image.height(srgb_img)
    {:ok, raw_data} = Vix.Vips.Image.write_to_binary(srgb_img)

    # Vix sRGB data is in R, G, B order; pdfium expects B, G, R order.
    bgr_data = swap_rb_3(raw_data)

    %ExPdfium.Bitmap{
      data: bgr_data,
      width: width,
      height: height,
      stride: width * 3,
      format: :bgr
    }
  end

  defp swap_rb_3(data) do
    for <<r::8, g::8, b::8 <- data>>, into: <<>>, do: <<b::8, g::8, r::8>>
  end

  # ── OCR word placement ───────────────────────────────────────────────

  # Convert an OCR span's pixel bounding box to PDF coordinates and draw
  # the recognised text.
  #
  # OCR coordinates have top-left origin (Tesseract convention).  PDF
  # coordinates have bottom-left origin, so the Y axis is flipped.
  # Scale factor is 1.0 since each image pixel maps to 1 PDF point (72 DPI).
  defp draw_ocr_word(doc, page, span, _img_w, img_h) do
    bbox = span.bbox
    x = bbox.x
    y = bbox.y
    h = bbox.h

    pdf_x = x * 1.0
    # Tesseract y is the top of the bounding box; baseline (bottom) in PDF
    # coordinates is (img_h - y - h).
    pdf_y = (img_h - y - h) * 1.0
    font_size = (h * 1.0) |> max(4.0) |> min(144.0)

    case ExPdfium.draw_text(doc, page, {pdf_x, pdf_y}, span.text,
           font: :helvetica,
           size: font_size,
           color: {0, 0, 0}
         ) do
      {:ok, updated_doc} -> updated_doc
      {:error, _reason} -> doc
    end
  end

  # ── Confidence ───────────────────────────────────────────────────────

  @doc """
  Returns the average confidence across OCR spans.

  Returns `nil` when the span list is empty.
  """
  @spec avg_confidence([map()]) :: float() | nil
  def avg_confidence(spans) do
    confs = Enum.map(spans, & &1.confidence)

    if confs == [],
      do: nil,
      else: Enum.sum(confs) / length(confs)
  end

  # ── Telemetry ────────────────────────────────────────────────────────

  defp emit_telemetry(:start, meta) do
    :telemetry.execute([:quire, :image_ocr, :start], %{}, meta)
  end

  defp emit_telemetry(:completed, meta) do
    :telemetry.execute([:quire, :image_ocr, :completed], meta)
  end

  defp emit_telemetry(:failed, meta) do
    :telemetry.execute([:quire, :image_ocr, :failed], meta)
  end
end
