defmodule Quire.Render.Pdfium do
  @moduledoc """
  PDFium-based render engine — rasterisation, text extraction, and document
  introspection (§7.2, §7.3).

  Wraps `ExPdfium` (== 0.5.1, via pdfium-render) behind the `Quire.Render`
  behaviour.

  ## Size and page limits

  * Input size cap: **500 MB** before the NIF touches the data.
  * Page count cap: **65 535** (pdfium-render's natural 16-bit limit).

  ## Dirty CPU

  `render_page/3` and `thumbnails/2` delegate to pdfium's rasteriser, which
  blocks the calling OS thread for potentially hundreds of milliseconds.
  ExPdfium's NIF already runs its render calls inside Rust's thread pool
  (`spawn_blocking`), so no separate DirtyCpu annotation is needed.  However,
  if these functions were backed by a bare NIF directly, they **would** need
  `:dirty_cpu` on their NIF spec.
  """

  @behaviour Quire.Render

  alias Quire.Storage
  alias Quire.Storage.Ref

  # 500 MB in bytes
  @max_input_bytes 500 * 1024 * 1024
  @max_pages 65_535

  @doc false
  @impl Quire.Render
  def page_count(ref) do
    with_doc(ref, fn doc ->
      with {:ok, count} <- ok!(ExPdfium.page_count(doc), :page_count) do
        if count > @max_pages do
          {:error,
           error(
             :page_count,
             :invalid_argument,
             "Page count #{count} exceeds maximum of #{@max_pages}"
           )}
        else
          {:ok, count}
        end
      end
    end)
  end

  @doc false
  @impl Quire.Render
  def page_geometry(ref) do
    with_doc(ref, fn doc ->
      with {:ok, count} <- ok!(ExPdfium.page_count(doc), :page_geometry) do
        pages =
          Enum.reduce_while(0..(count - 1), {:ok, []}, fn page, {:ok, acc} ->
            case ExPdfium.page_info(doc, page) do
              {:ok, info} ->
                {:cont,
                 {:ok,
                  [
                    %{
                      width: trunc(info.width),
                      height: trunc(info.height),
                      rotate: info.rotation
                    }
                    | acc
                  ]}}

              {:error, reason} ->
                {:halt,
                 {:error,
                  error(
                    :page_geometry,
                    :nif,
                    "page_info for page #{page} failed: #{inspect(reason)}"
                  )}}
            end
          end)

        case pages do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          {:error, _} = err -> err
        end
      end
    end)
  end

  @doc false
  @impl Quire.Render
  def render_page(ref, page_num, opts) do
    dpi = Keyword.get(opts, :dpi, 150)

    with_doc(ref, fn doc ->
      with {:ok, bitmap} <- ok!(ExPdfium.render_page(doc, page_num, dpi: dpi), :render_page) do
        {:ok, bitmap_to_png!(bitmap)}
      end
    end)
  end

  @doc false
  @impl Quire.Render
  def thumbnails(ref, opts) do
    pages = Keyword.get(opts, :pages, [0])
    max_dimension = Keyword.get(opts, :max_dimension, 256)

    with_doc(ref, fn doc ->
      pages
      |> Enum.reduce_while({:ok, []}, fn page, {:ok, acc} ->
        case ExPdfium.page_info(doc, page) do
          {:ok, info} ->
            scale = max_dimension / max(info.width, info.height)
            w = round(info.width * scale)
            h = round(info.height * scale)

            case ExPdfium.render_page(doc, page, width: w, height: h) do
              {:ok, bitmap} ->
                {:cont, {:ok, [bitmap_to_png!(bitmap) | acc]}}

              {:error, reason} ->
                {:halt,
                 {:error,
                  error(
                    :thumbnails,
                    :nif,
                    "render_page for page #{page} failed: #{inspect(reason)}"
                  )}}
            end

          {:error, reason} ->
            {:halt,
             {:error,
              error(:thumbnails, :nif, "page_info for page #{page} failed: #{inspect(reason)}")}}
        end
      end)
      |> case do
        {:ok, pngs} -> {:ok, Enum.reverse(pngs)}
        {:error, _} = err -> err
      end
    end)
  end

  @doc false
  @impl Quire.Render
  def extract_text(ref, opts) do
    with_doc(ref, fn doc ->
      with {:ok, count} <- ok!(ExPdfium.page_count(doc), :extract_text) do
        pages =
          Enum.reduce_while(0..(count - 1), {:ok, []}, fn page, {:ok, acc} ->
            case ExPdfium.text_segments(doc, page) do
              {:ok, segments} ->
                spans =
                  Enum.map(segments, fn s ->
                    %{text: s.text, bounds: s.bounds}
                  end)

                {:cont, {:ok, [%{page: page, spans: spans} | acc]}}

              {:error, _reason} ->
                # Fallback to extract_text/2 for repair mode
                page_text =
                  case ExPdfium.extract_text(doc, page, opts) do
                    {:ok, t} -> t
                    _ -> ""
                  end

                {:cont, {:ok, [%{page: page, spans: [%{text: page_text, bounds: nil}]} | acc]}}
            end
          end)

        case pages do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          {:error, _} = err -> err
        end
      end
    end)
  end

  @doc false
  @impl Quire.Render
  def search(ref, query, opts) do
    with_doc(ref, fn doc ->
      with {:ok, count} <- ok!(ExPdfium.page_count(doc), :search) do
        results =
          Enum.reduce_while(0..(count - 1), {:ok, []}, fn page, {:ok, acc} ->
            case ExPdfium.search_text(doc, page, query, opts) do
              {:ok, matches} ->
                results =
                  Enum.map(matches, fn m ->
                    Map.put(m, :page, page)
                  end)

                {:cont, {:ok, results ++ acc}}

              {:error, _reason} ->
                {:cont, {:ok, acc}}
            end
          end)

        case results do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          {:error, _} = err -> err
        end
      end
    end)
  end

  @doc false
  @impl Quire.Render
  def form_fields(ref) do
    with_doc(ref, fn doc ->
      ok!(ExPdfium.form_fields(doc), :form_fields)
    end)
  end

  @doc false
  @impl Quire.Render
  def annotations(ref) do
    with_doc(ref, fn doc ->
      with {:ok, count} <- ok!(ExPdfium.page_count(doc), :annotations) do
        results =
          Enum.reduce_while(0..(count - 1), {:ok, []}, fn page, {:ok, acc} ->
            case ExPdfium.annotations(doc, page) do
              {:ok, anns} -> {:cont, {:ok, anns ++ acc}}
              {:error, _reason} -> {:cont, {:ok, acc}}
            end
          end)

        case results do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          {:error, _} = err -> err
        end
      end
    end)
  end

  @doc false
  @impl Quire.Render
  def extract_images(ref, _opts) do
    with_doc(ref, fn doc ->
      with {:ok, count} <- ok!(ExPdfium.page_count(doc), :extract_images) do
        results =
          Enum.reduce_while(0..(count - 1), {:ok, []}, fn page, {:ok, acc} ->
            case ExPdfium.images(doc, page) do
              {:ok, images} ->
                image_results =
                  Enum.reduce_while(images, {:ok, acc}, fn img, {:ok, inner_acc} ->
                    case ExPdfium.image_data(doc, page, img.index) do
                      {:ok, bitmap} ->
                        png = bitmap_to_png!(bitmap)

                        case Storage.put(png, []) do
                          {:ok, ref} -> {:cont, {:ok, [ref | inner_acc]}}
                          {:error, reason} -> {:halt, {:error, reason}}
                        end

                      {:error, reason} ->
                        {:halt,
                         {:error,
                          error(
                            :extract_images,
                            :nif,
                            "image_data for page #{page} index #{img.index} failed: #{inspect(reason)}"
                          )}}
                    end
                  end)

                case image_results do
                  {:ok, _} -> {:cont, image_results}
                  {:error, _} -> {:halt, image_results}
                end

              {:error, _reason} ->
                {:cont, {:ok, acc}}
            end
          end)

        case results do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          {:error, _} = err -> err
        end
      end
    end)
  end

  @doc false
  @impl Quire.Render
  def outline(ref) do
    with_doc(ref, fn doc ->
      ok!(ExPdfium.outline(doc), :outline)
    end)
  end

  @doc false
  @impl Quire.Render
  def import_pages(source_ref, dest_ref, page_nums) do
    with {:ok, src_bytes} <- get_capped_bytes(source_ref),
         {:ok, dest_bytes} <- get_capped_bytes(dest_ref) do
      with_open(src_bytes, fn src_doc ->
        with_open(dest_bytes, fn dest_doc ->
          with {:ok, extracted} <-
                 ok!(ExPdfium.extract_pages(src_doc, page_nums), :import_pages) do
            close_after(extracted, fn extracted ->
              with {:ok, merged} <-
                     ok!(ExPdfium.append(dest_doc, extracted), :import_pages) do
                close_after(merged, fn merged ->
                  with {:ok, pdf_bytes} <-
                         ok!(ExPdfium.save_to_bytes(merged), :import_pages) do
                    Storage.put(pdf_bytes, [])
                  end
                end)
              end
            end)
          end
        end)
      end)
    end
  end

  @doc false
  @impl Quire.Render
  def new_document(opts) do
    format = Keyword.get(opts, :format, "Letter")
    page_size = String.downcase(format) |> String.to_atom()

    case ExPdfium.new() do
      {:ok, doc} ->
        try do
          case ExPdfium.add_page(doc, page_size) do
            {:ok, _new_doc} ->
              case ExPdfium.save_to_bytes(doc) do
                {:ok, pdf_bytes} ->
                  Storage.put(pdf_bytes, [])

                {:error, reason} ->
                  {:error, error(:new_document, :nif, "save_to_bytes failed: #{inspect(reason)}")}
              end

            {:error, reason} ->
              {:error, error(:new_document, :nif, "add_page failed: #{inspect(reason)}")}
          end
        after
          ExPdfium.close(doc)
        end

      {:error, reason} ->
        {:error, error(:new_document, :nif, "new document failed: #{inspect(reason)}")}
    end
  end

  @doc false
  @impl Quire.Render
  def add_page(ref, page_size, opts) do
    page_num = Keyword.get(opts, :page, -1)

    with_doc(ref, fn doc ->
      case ExPdfium.add_page(doc, page_size, at: page_num) do
        {:ok, _new_doc} ->
          case ExPdfium.save_to_bytes(doc) do
            {:ok, pdf_bytes} ->
              Storage.put(pdf_bytes, [])

            {:error, reason} ->
              {:error, error(:add_page, :nif, "save_to_bytes failed: #{inspect(reason)}")}
          end

        {:error, :bad_page_size} ->
          {:error,
           error(:add_page, :invalid_argument, "Invalid page size: #{inspect(page_size)}")}

        {:error, reason} ->
          {:error, error(:add_page, :nif, "add_page failed: #{inspect(reason)}")}
      end
    end)
  end

  @doc false
  @impl Quire.Render
  def save(ref, _opts) do
    with_doc(ref, fn doc ->
      case ExPdfium.save_to_bytes(doc) do
        {:ok, pdf_bytes} ->
          Storage.put(pdf_bytes, [])

        {:error, reason} ->
          {:error, error(:save, :nif, "save_to_bytes failed: #{inspect(reason)}")}
      end
    end)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp error(operation, code, message) do
    %Quire.Engine.Error{
      engine: __MODULE__,
      operation: operation,
      code: code,
      message: message,
      detail: nil
    }
  end

  defp ok!({:ok, value}, _operation), do: {:ok, value}

  defp ok!({:error, reason}, operation) do
    {:error, error(operation, :nif, "#{operation} failed: #{inspect(reason)}")}
  end

  defp get_capped_bytes(%Ref{} = ref) do
    case Storage.get(ref) do
      {:ok, bytes} ->
        size = byte_size(bytes)

        if size > @max_input_bytes do
          {:error,
           error(
             :read,
             :invalid_argument,
             "Input size #{size} bytes exceeds maximum of #{@max_input_bytes} bytes"
           )}
        else
          {:ok, bytes}
        end

      {:error, reason} ->
        {:error, error(:read, :runtime, "Failed to read from storage: #{inspect(reason)}")}
    end
  end

  defp with_doc(ref, fun) when is_function(fun, 1) do
    with {:ok, bytes} <- get_capped_bytes(ref) do
      with_open(bytes, fun)
    end
  end

  defp with_open(bytes, fun) when is_function(fun, 1) do
    case ExPdfium.open_blob(bytes) do
      {:ok, doc} ->
        try do
          fun.(doc)
        after
          ExPdfium.close(doc)
        end

      {:error, reason} ->
        {:error, error(:open, :nif, "Failed to open PDF: #{inspect(reason)}")}
    end
  end

  defp close_after(doc, fun) when is_function(fun, 1) do
    try do
      fun.(doc)
    after
      ExPdfium.close(doc)
    end
  end

  @doc false
  def check do
    case ExPdfium.pdfium_version() do
      v when is_binary(v) -> :ok
      {:error, :pdfium_init_failed} -> {:error, "pdfium_init_failed"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

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
