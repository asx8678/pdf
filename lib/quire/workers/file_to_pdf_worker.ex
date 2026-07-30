defmodule Quire.Workers.FileToPdfWorker do
  @moduledoc ~S"""
  Oban worker for file-to-PDF conversion supporting all listed input formats.

  ## Supported formats

  | Type      | Extensions                          | Pipeline                              |
  |-----------|-------------------------------------|---------------------------------------|
  | Image     | png, jpg, jpeg, tiff, tif, bmp,    | Vix → ExPdfium (new + draw_image)    |
  |           | webp, gif, heic                     |                                       |
  | Office    | docx, xlsx, pptx, odt, ods, odp,   | Office.Reader → Layout → Writer.Html |
  |           | rtf                                 | → ChromicPDF                          |
  | Text      | txt, csv, md                        | Direct HTML wrapper → ChromicPDF     |

  Calls `Documents.ingest/3` with the resulting PDF, creating a new document.

  ## Job args

      %{
        "bytes"    => base64_bytes,  # required — file content
        "filename" => "report.docx", # required — extension used for format routing
        "title"    => "Report",      # optional — defaults to filename root
        "scope_id" => scope_id       # optional — for Documents.ingest
      }
  """

  use Oban.Worker,
    queue: :convert,
    unique: [period: 60, fields: [:worker, :args]],
    max_attempts: 2

  use Quire.Workers.Base

  @image_extensions ~w(.png .jpg .jpeg .tiff .tif .bmp .webp .gif .heic)
  @office_extensions ~w(.docx .xlsx .pptx .odt .ods .odp .rtf)
  @text_extensions ~w(.txt .csv .md)

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Classifies a file extension into a format category.

  Returns one of `:text`, `:image`, `:office`, or `:unknown`.
  """
  def classify_ext(ext) do
    cond do
      ext in @text_extensions -> :text
      ext in @image_extensions -> :image
      ext in @office_extensions -> :office
      true -> :unknown
    end
  end

  @doc false
  @impl true
  def perform(%Oban.Job{args: args}) do
    filename = args["filename"] || ""
    ext = filename |> Path.extname() |> String.downcase()
    bytes = decode_bytes(args["bytes"])
    title = args["title"] || Path.rootname(filename)

    result = dispatch(bytes, ext, title)

    case result do
      {:ok, pdf_bytes} when is_binary(pdf_bytes) ->
        case persist(pdf_bytes, title, args) do
          {:ok, _doc} ->
            emit_telemetry(:completed, %{filename: filename, ext: ext})
            :ok

          {:error, reason} ->
            emit_telemetry(:failed, %{filename: filename, ext: ext, error: inspect(reason)})
            {:error, reason}
        end

      {:ok, _doc} ->
        emit_telemetry(:completed, %{filename: filename, ext: ext})
        :ok

      {:error, reason} ->
        emit_telemetry(:failed, %{filename: filename, ext: ext, error: inspect(reason)})
        {:error, reason}
    end
  end

  # ── Dispatch ───────────────────────────────────────────────────────────

  defp dispatch(bytes, ext, title) when ext in @image_extensions do
    convert_image(bytes, title)
  end

  defp dispatch(bytes, ext, title) when ext in @office_extensions do
    convert_office(bytes, ext, title)
  end

  defp dispatch(bytes, ext, title) when ext in @text_extensions do
    convert_text(bytes, title)
  end

  defp dispatch(_bytes, ".pdf", _title) do
    {:error, "PDF pass-through not implemented here — use Documents.ingest directly"}
  end

  defp dispatch(_bytes, ext, _title) do
    {:error, "Unsupported format: #{ext}"}
  end

  # ── Image → PDF (Vix → ExPdfium) ─────────────────────────────────────

  defp convert_image(image_bytes, _title) do
    with {:ok, img} <- Vix.Vips.Image.new_from_buffer(image_bytes),
         {:ok, srgb} <- Vix.Vips.Operation.colourspace(img, :VIPS_INTERPRETATION_sRGB) do
      width = Vix.Vips.Image.width(srgb)
      height = Vix.Vips.Image.height(srgb)

      # Build ExPdfium Bitmap from Vix sRGB data
      bitmap = vips_to_pdfium_bitmap(srgb, width, height)

      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, {width * 1.0, height * 1.0})

      {:ok, doc} =
        ExPdfium.draw_image(doc, 0, bitmap,
          at: %{left: 0.0, bottom: 0.0, right: width * 1.0, top: height * 1.0}
        )

      result = ExPdfium.save_to_bytes(doc)
      ExPdfium.close(doc)
      result
    end
  end

  # Vix sRGB → ExPdfium.Bitmap (BGR byte order)
  defp vips_to_pdfium_bitmap(img, width, height) do
    {:ok, raw_data} = Vix.Vips.Image.write_to_binary(img)
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

  # ── Office → HTML → PDF ──────────────────────────────────────────────

  defp convert_office(bytes, ext, title) do
    format = String.to_atom(String.trim_leading(ext, "."))
    reader = reader_for_format(format)

    if is_nil(reader) do
      {:error, "No reader available for format: #{format}"}
    else
      with {:ok, layout} <- reader.read(bytes),
           {:ok, html} <- Quire.Office.Writer.Html.write(layout, :html, []) do
        html_to_pdf(html, title)
      end
    end
  end

  defp reader_for_format(:docx), do: Quire.Office.Reader.Docx
  defp reader_for_format(:xlsx), do: Quire.Office.Reader.Xlsx
  defp reader_for_format(:pptx), do: Quire.Office.Reader.Pptx
  defp reader_for_format(:odt), do: Quire.Office.Reader.Odt
  defp reader_for_format(:ods), do: Quire.Office.Reader.Ods
  defp reader_for_format(:odp), do: Quire.Office.Reader.Odp
  defp reader_for_format(:rtf), do: Quire.Office.Reader.Rtf
  defp reader_for_format(_), do: nil

  # ── Text → HTML → PDF ────────────────────────────────────────────────

  defp convert_text(bytes, _title) do
    html = text_to_html(String.trim(bytes))
    html_to_pdf(html, nil)
  end

  @doc """
  Wraps plain text in an HTML document suitable for ChromicPDF.
  Exposed for testing; the pre tag preserves whitespace and line breaks.
  """
  def text_to_html(text) do
    ~s[<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/><style>body{font-family:monospace;padding:2em}pre{white-space:pre-wrap;word-wrap:break-word}</style></head><body><pre>#{escape_html(text)}</pre></body></html>]
  end

  # ── HTML → PDF via ChromicPDF ────────────────────────────────────────

  defp html_to_pdf(html, _title) do
    opts = [discard_stderr: true, page_size: :A4, offline: true]

    with {:ok, base64_pdf} <- ChromicPDF.print_to_pdf({:html, html}, opts) do
      decode_pdf(base64_pdf)
    end
  end

  # ── Persistence ──────────────────────────────────────────────────────

  defp persist(pdf_bytes, title, args) do
    scope_id = args["scope_id"]

    if scope_id do
      scope = %{id: scope_id}
      Quire.Documents.ingest(pdf_bytes, scope, title: title)
    else
      # No scope — caller will handle persistence
      {:ok, pdf_bytes}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp decode_bytes(nil), do: <<>>
  defp decode_bytes(b64) when is_binary(b64), do: Base.decode64!(b64)

  defp decode_pdf(base64_str) when is_binary(base64_str) do
    {:ok, Base.decode64!(base64_str)}
  end

  defp escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_html(_), do: ""

  defp emit_telemetry(event, metadata) do
    :telemetry.execute([:quire, :file_to_pdf, event], %{duration: nil}, metadata)
  rescue
    _ -> :ok
  end
end
