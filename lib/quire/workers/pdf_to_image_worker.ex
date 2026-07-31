defmodule Quire.Workers.PdfToImageWorker do
  @moduledoc ~S"""
  Oban worker for converting PDF pages to image files (PNG, JPEG, TIFF, WebP).

  Supports per-page image output (packaged as ZIP) and multipage TIFF output.
  Uses `Quire.Render.render_page/3` (PDFium) for rasterisation and
  `Vix.Vips` for re-encoding and multipage assembly.

  ## Queue

  Runs on the `:convert` queue, serialised (concurrency 1, §7.2).

  ## Job args

      %{
        "doc_id"         => doc_id,                # required
        "revision_id"    => revision_id,           # required
        "format"         => "png",                 # optional — png, jpeg, tiff, webp
        "dpi"            => 150,                   # optional — 72–600, clamped
        "page_range"     => [0, 1, 2] or :all,     # optional — defaults to :all
        "multipage_tiff" => false,                 # optional — format must be tiff
        "operation_id"   => op_id                  # optional, for progress reporting
      }

  ## Persistence

  Follows the `ConvertWorker`/`OcrWorker` pattern: render → `Storage.put` →
  `Documents.create_revision` with a `source` map referencing the stored blob.

  ## Page rendering

  Uses `Task.async_stream` for concurrent page rendering with back-pressure.
  For large PDFs (500+ pages) this provides parallel rasterisation without
  overwhelming memory.

  `render_page/3` returns PNG bytes — for JPEG/TIFF/WebP the PNG is decoded
  via `Vix.Vips.Image.new_from_buffer/2` and re-encoded in the target format.
  """

  use Oban.Worker,
    queue: :convert,
    unique: [period: 60, fields: [:worker, :args]],
    max_attempts: 2

  use Quire.Workers.Base

  alias Quire.Repo
  alias Quire.Render
  alias Quire.Storage
  alias Quire.Documents
  alias Quire.Documents.{Document, Revision}

  @min_dpi 72
  @max_dpi 600
  @valid_formats ~w(png jpeg tiff webp)

  # ── Oban callback ──────────────────────────────────────────────────────

  @impl true
  def perform(%Oban.Job{args: args}) do
    with {:ok, dpi} <- validated_dpi(args["dpi"] || 150),
         {:ok, format} <- validated_format(args["format"] || "png"),
         :ok <- validate_multipage_tiff(args["multipage_tiff"], format),
         {:ok, operation_id, doc_id, _user_id} <-
           Quire.Operations.ensure_started(args, "pdf_to_image"),
         {:ok, revision} <- fetch_revision(args["revision_id"]),
         {:ok, ref} <- fetch_storage_ref(revision),
         {:ok, pages} <- resolve_pages(args["page_range"], ref) do
      total = length(pages)

      if total == 0 do
        Quire.Operations.fail(operation_id, doc_id, :no_pages)
        {:error, "No pages to render"}
      else
        Quire.Operations.progress(operation_id, doc_id, 0)

        result =
          render_pages(
            ref,
            pages,
            format,
            dpi,
            args["multipage_tiff"] || false,
            operation_id,
            doc_id,
            total
          )

        case result do
          {:ok, output_binary} ->
            persist_result(output_binary, args, format, args["multipage_tiff"] || false)
            Quire.Operations.finish(operation_id, doc_id)
            :ok

          {:error, reason} ->
            Quire.Operations.fail(operation_id, doc_id, reason)
            {:error, reason}
        end
      end
    else
      other -> other
    end
  end

  # ── Page rendering ─────────────────────────────────────────────────────

  defp render_pages(ref, pages, format, dpi, multipage_tiff, operation_id, doc_id, total) do
    result =
      pages
      |> Task.async_stream(
        fn page_num ->
          # Tasks only render — progress is reported by the single consumer
          # process below so broadcasts stay strictly monotonic. Reporting
          # from inside the tasks would let a task that finished early
          # broadcast its % ahead of an earlier page's (the increment and
          # the broadcast are not atomic — a task can be preempted between
          # them), producing a non-monotonic stream under load.
          {page_num, render_single_page(ref, page_num, dpi, format)}
        end,
        max_concurrency: 4,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.reduce_while({:ok, [], 0}, fn
        {:ok, {_page_num, {:ok, binary}}}, {:ok, acc, done} ->
          done = done + 1
          # ordered: true ⇒ results arrive in input order, so `done` — and
          # the percentage derived from it — is monotonic by construction
          # and emitted from a single process (the ordered reduce).
          report_progress(operation_id, doc_id, floor(done * 100 / total))
          {:cont, {:ok, [binary | acc], done}}

        {:ok, {_page_num, {:error, reason}}}, _acc ->
          {:halt, {:error, reason}}

        {:error, reason}, _acc ->
          {:halt, {:error, "Render task failed: #{inspect(reason)}"}}
      end)

    case result do
      {:ok, page_binaries, _done} ->
        page_binaries = Enum.reverse(page_binaries)

        if multipage_tiff do
          assemble_multipage_tiff(page_binaries)
        else
          package_zip(page_binaries, pages, format)
        end

      {:error, _} = err ->
        err
    end
  end

  defp render_single_page(ref, page_num, dpi, target_format) do
    with {:ok, png_bytes} <- Render.render_page(ref, page_num, dpi: dpi) do
      if target_format == "png" do
        {:ok, png_bytes}
      else
        reencode_via_vix(png_bytes, target_format)
      end
    end
  end

  defp reencode_via_vix(png_bytes, format) do
    ext = "." <> format

    with {:ok, image} <- Vix.Vips.Image.new_from_buffer(png_bytes, []),
         {:ok, encoded} <- Vix.Vips.Image.write_to_buffer(image, ext, []) do
      {:ok, encoded}
    else
      {:error, reason} ->
        {:error, "Image re-encoding to #{format} failed: #{inspect(reason)}"}
    end
  end

  # ── ZIP packaging (single images per page) ─────────────────────────────

  defp package_zip(page_binaries, pages, format) do
    ext = "." <> format

    entries =
      pages
      |> Enum.zip(page_binaries)
      |> Enum.map(fn {page_num, binary} ->
        {String.to_charlist("page-#{page_num}#{ext}"), binary}
      end)

    case :zip.create(~c'images.zip', entries, [:memory]) do
      {:ok, ~c'images.zip', zip_bytes} ->
        {:ok, zip_bytes}

      {:ok, {~c'images.zip', zip_bytes}} ->
        {:ok, zip_bytes}

      {:ok, _other, zip_bytes} ->
        {:ok, zip_bytes}

      {:error, reason} ->
        {:error, "ZIP creation failed: #{inspect(reason)}"}
    end
  end

  # ── Multipage TIFF assembly ────────────────────────────────────────────

  defp assemble_multipage_tiff(page_binaries) do
    images_result =
      Enum.reduce_while(page_binaries, {:ok, []}, fn png_bytes, {:ok, acc} ->
        case Vix.Vips.Image.new_from_buffer(png_bytes, []) do
          {:ok, img} ->
            {:cont, {:ok, [img | acc]}}

          {:error, reason} ->
            {:halt, {:error, "Failed to decode page image: #{inspect(reason)}"}}
        end
      end)

    with {:ok, images} <- images_result do
      images = Enum.reverse(images)

      case images do
        [single_image] ->
          # Single page — save as regular TIFF
          case Vix.Vips.Operation.tiffsave_buffer(single_image,
                 compression: :VIPS_FOREIGN_TIFF_COMPRESSION_JPEG
               ) do
            {:ok, tiff_bytes} -> {:ok, tiff_bytes}
            {:error, reason} -> {:error, "TIFF save failed: #{inspect(reason)}"}
          end

        _multiple ->
          # Multiple pages — arrayjoin vertically, then save with page_height
          first_height = Vix.Vips.Image.height(hd(images))

          with {:ok, joined} <- Vix.Vips.Operation.arrayjoin(images, across: 1),
               {:ok, tiff_bytes} <-
                 Vix.Vips.Operation.tiffsave_buffer(joined,
                   page_height: first_height,
                   compression: :VIPS_FOREIGN_TIFF_COMPRESSION_JPEG
                 ) do
            {:ok, tiff_bytes}
          else
            {:error, reason} ->
              {:error, "Multipage TIFF assembly failed: #{inspect(reason)}"}
          end
      end
    end
  end

  # ── Validation ─────────────────────────────────────────────────────────

  defp validated_dpi(dpi) when is_integer(dpi) and dpi >= @min_dpi and dpi <= @max_dpi,
    do: {:ok, dpi}

  defp validated_dpi(dpi) when is_integer(dpi) and dpi < @min_dpi, do: {:ok, @min_dpi}
  defp validated_dpi(dpi) when is_integer(dpi) and dpi > @max_dpi, do: {:ok, @max_dpi}
  defp validated_dpi(_), do: {:ok, 150}

  defp validated_format(format) when is_binary(format) do
    f = String.downcase(format)

    if f in @valid_formats do
      {:ok, f}
    else
      {:error,
       "Unsupported format '#{format}'. Must be one of: #{Enum.join(@valid_formats, ", ")}"}
    end
  end

  defp validated_format(nil), do: {:ok, "png"}

  defp validate_multipage_tiff(true, "tiff"), do: :ok

  defp validate_multipage_tiff(true, _),
    do: {:error, "multipage_tiff is only supported for format 'tiff'"}

  defp validate_multipage_tiff(_, _), do: :ok

  # ── Page range resolution ──────────────────────────────────────────────

  defp fetch_revision(revision_id) do
    case Repo.get(Revision, revision_id) do
      nil -> {:error, "Revision #{revision_id} not found"}
      revision -> {:ok, revision}
    end
  end

  defp fetch_storage_ref(revision) do
    case Revision.storage_ref(revision) do
      nil -> {:error, "No storage ref on revision #{revision.id}"}
      ref -> {:ok, ref}
    end
  end

  defp resolve_pages(:all, ref) do
    with {:ok, count} <- Render.page_count(ref) do
      {:ok, Enum.to_list(0..(count - 1))}
    end
  end

  defp resolve_pages(nil, ref) do
    resolve_pages(:all, ref)
  end

  defp resolve_pages(page_range, _ref) when is_list(page_range) do
    pages = page_range |> Enum.filter(&is_integer/1) |> Enum.uniq() |> Enum.sort()
    {:ok, pages}
  end

  defp resolve_pages(_, _ref), do: {:ok, []}

  # ── Progress reporting ─────────────────────────────────────────────────

  defp report_progress(nil, _doc_id, _pct), do: :ok

  defp report_progress(operation_id, doc_id, pct) when is_integer(pct) do
    pct = if pct > 100, do: 100, else: pct
    pct = if pct < 0, do: 0, else: pct
    Quire.Operations.progress(operation_id, doc_id, pct)
  end

  # ── Persistence ────────────────────────────────────────────────────────

  defp persist_result(output_binary, args, format, multipage_tiff) do
    doc_id = args["doc_id"]
    is_zip = not multipage_tiff

    filename =
      if is_zip do
        "images.zip"
      else
        "output.#{format}"
      end

    content_type =
      if is_zip do
        "application/zip"
      else
        "image/tiff"
      end

    label =
      if is_zip do
        "Export to #{String.upcase(format)} (ZIP)"
      else
        "Export to multipage TIFF"
      end

    doc = Repo.get(Document, doc_id)

    if is_nil(doc) do
      {:error, "Document #{doc_id} not found"}
    else
      case Storage.put(output_binary, name: filename, content_type: content_type) do
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
            "multipage_tiff" => multipage_tiff
          }

          case Documents.create_revision(doc, label: label, source: source_map) do
            {:ok, new_rev} ->
              broadcast_revision(doc, new_rev)
              :ok

            {:error, changeset} ->
              {:error, "Failed to create revision: #{inspect(changeset.errors)}"}
          end

        {:error, reason} ->
          {:error, "Storage put failed: #{inspect(reason)}"}
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
end
