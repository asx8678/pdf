defmodule Quire.Render.Pdfium do
  @moduledoc """
  PDFium-based render engine — rasterisation, text extraction, and document
  introspection (§7.2, §7.3).

  Wraps `ExPdfium` (== 0.5.1, via pdfium-render) behind the `Quire.Render`
  behaviour. Every public callback emits telemetry through
  `Quire.Engine.trace/4`.

  ## Size and page limits

  * Input size cap: **500 MB** before the NIF touches the data.
  * Page count cap: **65 535** (pdfium-render's natural 16-bit limit).

  ## Dirty CPU

  `render_page/3` and `thumbnails/3` delegate to pdfium's rasteriser, which
  blocks the calling OS thread for potentially hundreds of milliseconds.
  ExPdfium's NIF already runs its render calls inside Rust's thread pool
  (`spawn_blocking`), so no separate DirtyCpu annotation is needed. However,
  if these functions were backed by a bare NIF directly, they **would** need
  `:dirty_cpu` on their NIF spec.
  """

  @behaviour Quire.Render

  alias Quire.Engine
  alias Quire.Storage
  alias Quire.Storage.Ref

  # 500 MB in bytes
  @max_input_bytes 500 * 1024 * 1024
  @max_pages 65_535

  @doc false
  @impl Quire.Render
  def page_count(ref) do
    Engine.trace(__MODULE__, :page_count, [ref], fn ->
      with_doc(ref, fn doc ->
        count = ok!(ExPdfium.page_count(doc))

        if count > @max_pages do
          raise ArgumentError,
                "Page count #{count} exceeds maximum of #{@max_pages}"
        end

        count
      end)
    end)
  end

  @doc false
  @impl Quire.Render
  def page_geometry(ref) do
    Engine.trace(__MODULE__, :page_geometry, [ref], fn ->
      with_doc(ref, fn doc ->
        count = ok!(ExPdfium.page_count(doc))

        Enum.map(0..(count - 1), fn page ->
          info = ok!(ExPdfium.page_info(doc, page))
          {trunc(info.width), trunc(info.height)}
        end)
      end)
    end)
  end

  @doc false
  @impl Quire.Render
  def render_page(ref, page, dpi) do
    Engine.trace(__MODULE__, :render_page, [ref, page, dpi], fn ->
      with_doc(ref, fn doc ->
        bitmap = ok!(ExPdfium.render_page(doc, page, dpi: dpi))
        bitmap_to_png!(bitmap)
      end)
    end)
  end

  @doc false
  @impl Quire.Render
  def thumbnails(ref, pages, max_dimension) do
    Engine.trace(__MODULE__, :thumbnails, [ref, pages, max_dimension], fn ->
      with_doc(ref, fn doc ->
        Enum.map(pages, fn page ->
          info = ok!(ExPdfium.page_info(doc, page))
          scale = max_dimension / max(info.width, info.height)
          w = round(info.width * scale)
          h = round(info.height * scale)

          bitmap = ok!(ExPdfium.render_page(doc, page, width: w, height: h))
          bitmap_to_png!(bitmap)
        end)
      end)
    end)
  end

  @doc false
  @impl Quire.Render
  def extract_text(ref, opts) do
    Engine.trace(__MODULE__, :extract_text, [ref, opts], fn ->
      with_doc(ref, fn doc ->
        text = ok!(ExPdfium.extract_text(doc))

        if Keyword.get(opts, :repair) do
          {text, _report} = ExPdfium.Text.repair(text, regimes: :auto)
          text
        else
          text
        end
      end)
    end)
  end

  @doc false
  @impl Quire.Render
  def search(ref, query, opts) do
    Engine.trace(__MODULE__, :search, [ref, query, opts], fn ->
      with_doc(ref, fn doc ->
        count = ok!(ExPdfium.page_count(doc))

        Enum.flat_map(0..(count - 1), fn page ->
          case ExPdfium.search_text(doc, page, query, opts) do
            {:ok, matches} ->
              Enum.map(matches, &Map.put(&1, :page, page))

            {:error, _reason} ->
              []
          end
        end)
      end)
    end)
  end

  @doc false
  @impl Quire.Render
  def form_fields(ref) do
    Engine.trace(__MODULE__, :form_fields, [ref], fn ->
      with_doc(ref, fn doc ->
        ok!(ExPdfium.form_fields(doc))
      end)
    end)
  end

  @doc false
  @impl Quire.Render
  def annotations(ref) do
    Engine.trace(__MODULE__, :annotations, [ref], fn ->
      with_doc(ref, fn doc ->
        count = ok!(ExPdfium.page_count(doc))

        Enum.flat_map(0..(count - 1), fn page ->
          case ExPdfium.annotations(doc, page) do
            {:ok, anns} -> anns
            {:error, _reason} -> []
          end
        end)
      end)
    end)
  end

  @doc false
  @impl Quire.Render
  def extract_images(ref, opts) do
    Engine.trace(__MODULE__, :extract_images, [ref, opts], fn ->
      with_doc(ref, fn doc ->
        count = ok!(ExPdfium.page_count(doc))

        Enum.flat_map(0..(count - 1), fn page ->
          case ExPdfium.images(doc, page) do
            {:ok, images} ->
              Enum.map(images, fn img ->
                bitmap = ok!(ExPdfium.image_data(doc, page, img.index))
                bitmap_to_png!(bitmap)
              end)

            {:error, _reason} ->
              []
          end
        end)
      end)
    end)
  end

  @doc false
  @impl Quire.Render
  def outline(ref) do
    Engine.trace(__MODULE__, :outline, [ref], fn ->
      with_doc(ref, fn doc ->
        ok!(ExPdfium.outline(doc))
      end)
    end)
  end

  # ── Unsupported ──────────────────────────────────────────────────────────

  @doc false
  @impl Quire.Render
  def import_pages(_dest, _source, _pages) do
    {:error, unsupported_error(:import_pages)}
  end

  @doc false
  @impl Quire.Render
  def new_document(_opts) do
    {:error, unsupported_error(:new_document)}
  end

  @doc false
  @impl Quire.Render
  def add_page_objects(_doc, _objects) do
    {:error, unsupported_error(:add_page_objects)}
  end

  @doc false
  @impl Quire.Render
  def save(_doc) do
    {:error, unsupported_error(:save)}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp unsupported_error(operation) do
    %Engine.Error{
      engine: __MODULE__,
      operation: operation,
      code: :invalid_argument,
      message: "Direct PDF structure writes use Quire.Pdf, not Render.Pdfium",
      detail: nil
    }
  end

  @doc false
  defp get_capped_bytes!(%Ref{} = ref) do
    {:ok, bytes} = Storage.get(ref)
    size = byte_size(bytes)

    if size > @max_input_bytes do
      raise ArgumentError,
            "Input size #{size} bytes exceeds maximum of #{@max_input_bytes} bytes"
    end

    bytes
  end

  @doc false
  defp with_doc(ref, fun) do
    bytes = get_capped_bytes!(ref)

    case ExPdfium.open_blob(bytes) do
      {:ok, doc} ->
        try do
          fun.(doc)
        after
          ExPdfium.close(doc)
        end

      {:error, reason} ->
        raise "Failed to open PDF: #{inspect(reason)}"
    end
  end

  @doc false
  defp ok!({:ok, value}), do: value

  defp ok!({:error, reason}) do
    raise "ExPdfium operation failed: #{inspect(reason)}"
  end

  @doc false
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
end
