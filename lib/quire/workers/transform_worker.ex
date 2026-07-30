defmodule Quire.Workers.TransformWorker do
  @moduledoc ~S"""
  Oban worker for page structural operations — the splice primitive for
  reorder, insert, extract, replace, reverse, delete, and rotate (§T-061).

  Every operation builds a new document by selecting pages (in the desired
  order) from the source, applying per‑page rotation and box changes, saving
  as a new revision, and updating the document's `current_revision_id`.

  ## Queue

  Runs on the `:transform` queue, serialised (concurrency 1, §7.2).

  ## Job args

      %{
        "doc_id"        => doc_id,           # required
        "operation"     => "page_splice",    # operation discriminator
        "page_order"    => [0, 2, 1, 3],     # source page indices in desired order
        "rotation"      => %{1 => 90},       # page-index → degrees (0/90/180/270)
        "boxes"         => %{0 => %{...}},   # page-index → box overrides (future)
        "operation_id"  => op_id             # optional, for progress reporting
      }

  ## Idempotency

  Work is not yet idempotent — the caller (controller / LiveView) is
  responsible for preventing double‑submit.  Once the operation enqueues a
  unique job key the (:transform) queue serialises execution so at most one
  transform runs at a time per document.  A future iteration should guard
  with `Base.guard_idempotent/2` using a deterministic revision id.
  """

  # Declare the Oban worker queue directly — Base.__using__ does NOT emit
  # `use Oban.Worker` because that would suppress the new/1 function export.
  use Oban.Worker, queue: :transform
  use Quire.Workers.Base, queue: :transform

  import Ecto.Query

  alias Quire.Repo
  alias Quire.Documents.{Annotation, Document, Page, PageText, Revision}

  # ── Oban callback ──────────────────────────────────────────────────────

  @doc false
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: args}) do
    operation = args["operation"]

    if operation == "export_images" do
      perform_export_images(args)
    else
      perform_transform(args)
    end
  end

  # Standard transform operations that produce a new document revision.
  defp perform_transform(args) do
    doc_id = args["doc_id"]
    operation = args["operation"]
    operation_id = args["operation_id"]

    with {:ok, doc} <- fetch_document(doc_id),
         {:ok, rev} <- Quire.Documents.current_revision(doc),
         %Quire.Storage.Ref{} = ref <- Revision.storage_ref(rev),
         {:ok, source_bytes} <- Quire.Storage.get(ref),
         {:ok, new_bytes} <- dispatch_page_op(operation, source_bytes, args) do
      # 4. Store the new document bytes.
      {:ok, new_ref} =
        Quire.Storage.put(new_bytes, name: doc.title, content_type: "application/pdf")

      # 5. Build revision source map (mirrors the shape in do_ingest/3).
      source_map = %{
        "storage_ref" => %{
          "adapter" => to_string(new_ref.adapter),
          "key" => new_ref.key,
          "name" => new_ref.name,
          "content_type" => new_ref.content_type,
          "byte_size" => new_ref.byte_size
        },
        "filename" => doc.title
      }

      {:ok, new_rev} =
        Quire.Documents.create_revision(doc,
          label: operation_label(operation),
          source: source_map
        )

      # Copy page and text caches from the previous revision.
      old_revision_id = rev.id
      preserved_map = compute_preserved_map(operation, args, doc.page_count)

      copy_page_caches(Repo, old_revision_id, new_rev.id, preserved_map)
      remap_sidecar_indices(Repo, old_revision_id, new_rev.id, preserved_map)

      # Enqueue text extraction if any pages are genuinely new or shifted.
      has_new_pages? = Enum.any?(preserved_map, fn {_new, old} -> is_nil(old) end)

      if has_new_pages? do
        %{revision_id: new_rev.id, document_id: doc.id}
        |> Quire.Workers.TextExtractWorker.new([])
        |> Oban.insert!()
      end

      # 6. Update document's current revision pointer.
      {:ok, _updated_doc} =
        doc
        |> Ecto.Changeset.change(%{current_revision_id: new_rev.id})
        |> Repo.update()

      # 7. Broadcast revision on the document's PubSub topic.
      Phoenix.PubSub.broadcast(
        Quire.PubSub,
        "document:#{doc_id}",
        {:revision, new_rev}
      )

      # 8. Report final progress.
      if operation_id do
        Quire.Workers.Base.report_progress(operation_id, doc_id, 100)
      end

      :ok
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, "no storage ref on current revision"}
    end
  end

  # ── Splice primitive (bytes → bytes) ──────────────────────────────────

  @doc ~S"""
  The splice primitive: build a new PDF from raw source bytes by selecting,
  reordering, and optionally rotating pages.

  `pages` is a list of `{page_index, rotation, box_overrides}` tuples where:

    * `page_index` — zero‑based page number in the **source** document
    * `rotation`   — `nil` (keep original rotation) or one of
                     `0` / `90` / `180` / `270`
    * `box_overrides` — `nil` (keep original boxes) or a map of box‑type →
      bounds (not yet implemented at the ExPdfium level; reserved for future
      use by T‑062 through T‑068).

  Returns `{:ok, new_pdf_bytes}` or `{:error, reason}`.
  """
  @spec page_splice(
          source_bytes :: binary(),
          pages :: [{non_neg_integer(), integer() | nil, map() | nil}]
        ) :: {:ok, binary()} | {:error, term()}
  def page_splice(source_bytes, pages) when is_binary(source_bytes) and is_list(pages) do
    # Open the source and create an empty result document.
    with {:ok, src_doc} <- ExPdfium.open_blob(source_bytes),
         {:ok, result_doc} <- ExPdfium.new() do
      try do
        accumulate_pages(src_doc, result_doc, pages)
      after
        ExPdfium.close(src_doc)
        ExPdfium.close(result_doc)
      end
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────

  # Extract each page from the source (in order), apply rotation and box
  # changes, and append it to the result document.
  defp accumulate_pages(src_doc, result_doc, pages) do
    result =
      Enum.reduce_while(pages, {:ok, result_doc}, fn {page_idx, rotation, boxes},
                                                     {:ok, acc_doc} ->
        case import_and_transform(src_doc, acc_doc, page_idx, rotation, boxes) do
          {:ok, doc} -> {:cont, {:ok, doc}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, final_doc} ->
        ExPdfium.save_to_bytes(final_doc)

      {:error, _} = err ->
        err
    end
  end

  # Import a single page from src_doc into dest_doc, applying rotation
  # and box overrides.
  defp import_and_transform(src_doc, dest_doc, page_idx, rotation, box_overrides \\ nil) do
    with {:ok, temp_doc} <- ExPdfium.extract_pages(src_doc, [page_idx]) do
      try do
        temp_doc = apply_rotation(temp_doc, rotation)
        temp_doc = apply_box_overrides(temp_doc, box_overrides)

        case ExPdfium.append(dest_doc, temp_doc) do
          {:ok, _} -> {:ok, dest_doc}
          {:error, _} = err -> err
        end
      after
        ExPdfium.close(temp_doc)
      end
    end
  end

  # Apply box overrides (crop, media, etc.) to a single-page temp_doc.
  # `box_overrides` is a map of box_type atom → {left, bottom, right, top}.
  # Returns the (possibly modified) temp_doc.
  defp apply_box_overrides(temp_doc, nil), do: temp_doc

  defp apply_box_overrides(temp_doc, overrides) when is_map(overrides) do
    # set_page_box may not be implemented in the bundled ExPdfium NIF —
    # use apply/3 to avoid a compile-time warning.
    if function_exported?(ExPdfium, :set_page_box, 7) do
      Enum.reduce(overrides, temp_doc, fn {box_type, {left, bottom, right, top}}, acc ->
        case apply(ExPdfium, :set_page_box, [acc, 0, box_type, left, bottom, right, top]) do
          {:ok, updated} -> updated
          {:error, _reason} -> acc
        end
      end)
    else
      temp_doc
    end
  end

  defp apply_rotation(doc, nil), do: doc
  defp apply_rotation(doc, 0), do: doc

  defp apply_rotation(doc, degrees) when degrees in [90, 180, 270] do
    {:ok, rotated} = ExPdfium.rotate_page(doc, 0, degrees)
    rotated
  end

  defp apply_rotation(_doc, degrees) do
    raise ArgumentError, "invalid rotation #{inspect(degrees)}; expected 0, 90, 180, or 270"
  end

  # Dispatch to the appropriate page operation handler.
  defp dispatch_page_op("page_size_margin", source_bytes, args) do
    perform_page_size_margin(source_bytes, args)
  end

  defp dispatch_page_op("insert_blank", source_bytes, args) do
    perform_insert(source_bytes, args)
  end

  defp dispatch_page_op("extract", source_bytes, args) do
    perform_extract(source_bytes, args)
  end

  defp dispatch_page_op("replace", source_bytes, args) do
    perform_replace(source_bytes, args)
  end

  defp dispatch_page_op("background", source_bytes, args) do
    perform_background(source_bytes, args)
  end

  defp dispatch_page_op("crop", source_bytes, args) do
    perform_crop(source_bytes, args)
  end

  defp dispatch_page_op("remove_crop", source_bytes, args) do
    perform_remove_crop(source_bytes, args)
  end

  defp dispatch_page_op("export_images", _source_bytes, _args) do
    {:ok, :export_images_done}
  end

  defp dispatch_page_op(_op, source_bytes, args) do
    splice_from_args(source_bytes, args)
  end

  # Build the pages tuple list from the job args.
  defp splice_from_args(source_bytes, args) do
    page_order = Map.get(args, "page_order", [])
    rotation = Map.get(args, "rotation", %{})
    boxes = Map.get(args, "boxes", %{})

    pages =
      Enum.map(page_order, fn idx ->
        {idx, rotation[idx], boxes[idx]}
      end)

    page_splice(source_bytes, pages)
  end

  @doc """
  Insert a blank page into the source PDF at the given 0‑based position.
  The blank page uses the specified page size (default `"a4"`).
  """
  @spec perform_insert(binary(), map()) :: {:ok, binary()} | {:error, term()}
  def perform_insert(source_bytes, args) do
    position = Map.get(args, "position", 0)
    page_size_name = Map.get(args, "page_size", "a4")
    page_size = String.to_existing_atom(page_size_name)

    with {:ok, blank_bytes} <- make_blank_page(page_size),
         {:ok, src_doc} <- ExPdfium.open_blob(source_bytes),
         {:ok, blank_doc} <- ExPdfium.open_blob(blank_bytes),
         {:ok, result_doc} <- ExPdfium.new() do
      try do
        {:ok, src_count} = ExPdfium.page_count(src_doc)
        page_order = build_insert_order(src_count, position)

        result =
          Enum.reduce_while(page_order, {:ok, result_doc}, fn
            :blank, {:ok, acc} ->
              case ExPdfium.append(acc, blank_doc) do
                {:ok, _} -> {:cont, {:ok, acc}}
                {:error, _} = err -> {:halt, err}
              end

            idx, {:ok, acc} ->
              import_and_transform(src_doc, acc, idx, nil)
          end)

        case result do
          {:ok, final_doc} -> ExPdfium.save_to_bytes(final_doc)
          {:error, _} = err -> err
        end
      after
        ExPdfium.close(src_doc)
        ExPdfium.close(blank_doc)
        ExPdfium.close(result_doc)
      end
    end
  end

  # Create a 1‑page blank PDF with the given page size.
  defp make_blank_page(page_size) do
    with {:ok, doc} <- ExPdfium.new(),
         {:ok, doc} <- ExPdfium.add_page(doc, page_size),
         {:ok, bytes} <- ExPdfium.save_to_bytes(doc) do
      ExPdfium.close(doc)
      {:ok, bytes}
    end
  end

  # Build source page indices with a :blank sentinel inserted at `position`.
  defp build_insert_order(src_count, position) when position >= src_count do
    Enum.to_list(0..(src_count - 1)) ++ [:blank]
  end

  defp build_insert_order(src_count, position) do
    prefix = Enum.to_list(0..(position - 1))
    suffix = Enum.to_list(position..(src_count - 1))
    prefix ++ [:blank | suffix]
  end

  # ── Page Size & Margin ────────────────────────────────────────────────────

  @doc ~S"""
  Apply page size and margin changes to every page in the document.

  Job args:
    * `page_order` — source page indices (all pages in order)
    * `page_size` — preset name (`"a4"`, `"letter"`, `"legal"`, `"tabloid"`, `"custom"`)
    * `width`, `height` — new page dimensions in points (for `"custom"` or as override)
    * `margin_top`, `margin_bottom`, `margin_left`, `margin_right` — margins in points

  Each page's MediaBox is set to the new dimensions. When margins are specified,
  the CropBox is shrunk inward by the margin amounts. The content is preserved
  as-is; when the box-setting API lands (ex_pdfium D4 upstream PR), the boxes
  will be applied via page_splice's `boxes` parameter.
  """
  @spec perform_page_size_margin(binary(), map()) :: {:ok, binary()} | {:error, term()}
  def perform_page_size_margin(source_bytes, args) do
    page_order = Map.get(args, "page_order", [])
    rotation = Map.get(args, "rotation", %{})

    page_size = Map.get(args, "page_size", "a4")
    width = Map.get(args, "width", 595)
    height = Map.get(args, "height", 842)
    margin_top = Map.get(args, "margin_top", 0)
    margin_bottom = Map.get(args, "margin_bottom", 0)
    margin_left = Map.get(args, "margin_left", 0)
    margin_right = Map.get(args, "margin_right", 0)

    {w, h} =
      if page_size == "custom" and width > 0 and height > 0 do
        {width, height}
      else
        {preset_w(page_size), preset_h(page_size)}
      end

    # Build the new MediaBox and CropBox for each page
    # MediaBox = [0, 0, w, h]
    # CropBox = [margin_left, margin_bottom, w - margin_right, h - margin_top]
    boxes =
      Map.new(page_order, fn idx ->
        {idx,
         %{
           media: {0, 0, w, h},
           crop: {margin_left, margin_bottom, w - margin_right, h - margin_top}
         }}
      end)

    pages =
      Enum.map(page_order, fn idx ->
        {idx, rotation[idx], boxes[idx]}
      end)

    page_splice(source_bytes, pages)
  end

  defp preset_w("a4"), do: 595
  defp preset_w("letter"), do: 612
  defp preset_w("legal"), do: 612
  defp preset_w("tabloid"), do: 792
  defp preset_w(_custom), do: 595

  defp preset_h("a4"), do: 842
  defp preset_h("letter"), do: 792
  defp preset_h("legal"), do: 1008
  defp preset_h("tabloid"), do: 1224
  defp preset_h(_custom), do: 842

  @doc ~S"""
  Apply a crop to pages: set CropBox shrunk by margins from MediaBox.

  Job args:
    * `page_order` — source page indices
    * `top`, `bottom`, `left`, `right` — margin amounts in points
  """
  @spec perform_crop(binary(), map()) :: {:ok, binary()} | {:error, term()}
  def perform_crop(source_bytes, args) do
    page_order = Map.get(args, "page_order", [])
    rotation = Map.get(args, "rotation", %{})
    margin_top = Map.get(args, "top", 0)
    margin_bottom = Map.get(args, "bottom", 0)
    margin_left = Map.get(args, "left", 0)
    margin_right = Map.get(args, "right", 0)

    # For each page, read the MediaBox and compute CropBox = MediaBox shrunk by margins.
    # We need to open the source to read per-page MediaBox values.
    pages =
      Enum.map(page_order, fn idx ->
        crop_box =
          compute_crop_box(
            source_bytes,
            idx,
            margin_top,
            margin_bottom,
            margin_left,
            margin_right
          )

        boxes = %{crop: crop_box}
        {idx, rotation[idx], boxes}
      end)

    page_splice(source_bytes, pages)
  end

  # Read a page's MediaBox from the source PDF and return the CropBox
  # shrunk by the given margins.
  defp compute_crop_box(source_bytes, page_idx, mt, mb, ml, mr) do
    with {:ok, doc} <- ExPdfium.open_blob(source_bytes) do
      try do
        case ExPdfium.page_info(doc, page_idx) do
          {:ok, info} ->
            media =
              info.boxes.media || %{left: 0.0, bottom: 0.0, right: info.width, top: info.height}

            {media.left + ml, media.bottom + mb, media.right - mr, media.top - mt}

          {:error, _} ->
            {ml, mb, 612 - mr, 792 - mt}
        end
      after
        ExPdfium.close(doc)
      end
    else
      {:error, _} -> {ml, mb, 612 - mr, 792 - mt}
    end
  end

  @doc ~S"""
  Remove crop: reset CropBox to MediaBox for every page.

  Job args:
    * `page_order` — source page indices
  """
  @spec perform_remove_crop(binary(), map()) :: {:ok, binary()} | {:error, term()}
  def perform_remove_crop(source_bytes, args) do
    page_order = Map.get(args, "page_order", [])
    rotation = Map.get(args, "rotation", %{})

    pages =
      Enum.map(page_order, fn idx ->
        crop_box = compute_media_box(source_bytes, idx)
        boxes = %{crop: crop_box}
        {idx, rotation[idx], boxes}
      end)

    page_splice(source_bytes, pages)
  end

  # Read a page's MediaBox and return it as the crop box (reset crop to media).
  defp compute_media_box(source_bytes, page_idx) do
    with {:ok, doc} <- ExPdfium.open_blob(source_bytes) do
      try do
        case ExPdfium.page_info(doc, page_idx) do
          {:ok, info} ->
            media =
              info.boxes.media || %{left: 0.0, bottom: 0.0, right: info.width, top: info.height}

            {media.left, media.bottom, media.right, media.top}

          {:error, _} ->
            {0, 0, 612, 792}
        end
      after
        ExPdfium.close(doc)
      end
    else
      {:error, _} -> {0, 0, 612, 792}
    end
  end

  @doc ~S"""
  Apply a background colour to pages.

  Draws a filled rectangle covering the full media box on each page in the
  given range, with the specified colour and opacity.  The rectangle is drawn
  on the page content stream.

  Job args:
    * `background.color` — hex colour string (e.g. `"#FF0000"`)
    * `background.opacity` — opacity 0–100 (mapped to alpha 0–255)
    * `background.page_range` — `"all"` or a page range like `"1-3,5"` (1‑based)
  """
  @spec perform_background(binary(), map()) :: {:ok, binary()} | {:error, term()}
  def perform_background(source_bytes, args) do
    bg = Map.get(args, "background", %{})
    color = Map.get(bg, "color", "#FFFFFF")
    opacity = Map.get(bg, "opacity", 100)
    page_range = Map.get(bg, "page_range", "all")

    {r, g, b} = parse_hex_color(color)
    alpha = round(opacity / 100 * 255) |> max(0) |> min(255)

    with {:ok, doc} <- ExPdfium.open_blob(source_bytes) do
      try do
        {:ok, count} = ExPdfium.page_count(doc)
        pages = resolve_page_range(page_range, count)

        result =
          Enum.reduce_while(pages, {:ok, doc}, fn page_idx, {:ok, doc} ->
            case ExPdfium.page_info(doc, page_idx) do
              {:ok, info} ->
                media =
                  info.boxes.media ||
                    %{left: 0.0, bottom: 0.0, right: info.width, top: info.height}

                case ExPdfium.draw_rectangle(doc, page_idx, media,
                       fill: {r, g, b, alpha},
                       stroke_width: 0
                     ) do
                  {:ok, doc} -> {:cont, {:ok, doc}}
                  {:error, _} = err -> {:halt, err}
                end

              {:error, _} = err ->
                {:halt, err}
            end
          end)

        case result do
          {:ok, doc} -> ExPdfium.save_to_bytes(doc)
          {:error, _} = err -> err
        end
      after
        ExPdfium.close(doc)
      end
    end
  end

  # Parse a hex colour string ("#FF0000" or "FF0000") to {r, g, b}.
  defp parse_hex_color("#" <> hex), do: parse_hex_color(hex)

  defp parse_hex_color(hex) when byte_size(hex) == 6 do
    {r, _} = Integer.parse(String.slice(hex, 0, 2), 16)
    {g, _} = Integer.parse(String.slice(hex, 2, 2), 16)
    {b, _} = Integer.parse(String.slice(hex, 4, 2), 16)
    {r, g, b}
  end

  defp parse_hex_color(_), do: {255, 255, 255}

  # Resolve a page range string to a list of 0‑based page indices.
  # "all" → all pages; otherwise "1-3,5" → [0, 1, 2, 4].
  defp resolve_page_range("all", count), do: Enum.to_list(0..(count - 1))

  defp resolve_page_range(range_str, _count) do
    range_str
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      part = String.trim(part)

      case String.split(part, "-") do
        [single] ->
          case Integer.parse(single) do
            {n, _} -> [n - 1]
            :error -> []
          end

        [start_str, end_str] ->
          case {Integer.parse(start_str), Integer.parse(end_str)} do
            {{s, _}, {e, _}} -> Enum.to_list((s - 1)..(e - 1))
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  defp fetch_document(doc_id) do
    case Repo.get(Document, doc_id) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  # ── Extract ──────────────────────────────────────────────────────────────

  @doc ~S"""
  Extract selected pages into a **new document**.

  Job args use the same `page_order` convention: only the selected page
  indices are included.  The worker builds a new PDF from those pages and
  returns the bytes; the handler creates the new document.
  """
  @spec perform_extract(binary(), map()) :: {:ok, binary()} | {:error, term()}
  def perform_extract(source_bytes, args) do
    splice_from_args(source_bytes, args)
  end

  # ── Replace ──────────────────────────────────────────────────────────────

  @doc ~S"""
  Replace selected pages with pages from an uploaded PDF.

  The job args contain:
    * `page_order` — source page indices (the results of removing selected
      pages from the original order)
    * `replacement_bytes` — raw bytes of the replacement PDF file
      (base64‑encoded in the job args)
    * `insert_at` — 0‑based position where replacement pages are inserted
  """
  @spec perform_replace(binary(), map()) :: {:ok, binary()} | {:error, term()}
  def perform_replace(source_bytes, args) do
    replacement_b64 = Map.fetch!(args, "replacement_bytes")
    replacement_bytes = Base.decode64!(replacement_b64)
    insert_at = Map.get(args, "insert_at", 0)

    page_order = Map.get(args, "page_order", [])

    with {:ok, src_doc} <- ExPdfium.open_blob(source_bytes),
         {:ok, repl_doc} <- ExPdfium.open_blob(replacement_bytes),
         {:ok, result_doc} <- ExPdfium.new() do
      try do
        {:ok, repl_count} = ExPdfium.page_count(repl_doc)

        # Build combined page order:
        # [source_before ..., :repl_0, :repl_1, ..., source_after ...]
        {before, after_src} = Enum.split(page_order, insert_at)

        repl_sentinels = Enum.map(0..(repl_count - 1), &{:repl, &1})
        combined = before ++ repl_sentinels ++ after_src

        result =
          Enum.reduce_while(combined, {:ok, result_doc}, fn
            {:repl, repl_idx}, {:ok, acc} ->
              with {:ok, temp_doc} <- ExPdfium.extract_pages(repl_doc, [repl_idx]) do
                try do
                  case ExPdfium.append(acc, temp_doc) do
                    {:ok, _} -> {:cont, {:ok, acc}}
                    {:error, _} = err -> {:halt, err}
                  end
                after
                  ExPdfium.close(temp_doc)
                end
              end

            src_idx, {:ok, acc} ->
              import_and_transform(src_doc, acc, src_idx, nil)
          end)

        case result do
          {:ok, final_doc} -> ExPdfium.save_to_bytes(final_doc)
          {:error, _} = err -> err
        end
      after
        ExPdfium.close(src_doc)
        ExPdfium.close(repl_doc)
        ExPdfium.close(result_doc)
      end
    end
  end

  # ── Export Images (T-066) ────────────────────────────────────────────────

  @doc ~S"""
  Extract all embedded raster images from the document, package them into a
  ZIP archive stored in Storage, and broadcast the download URL.

  Job args:
    * `doc_id` — the document to export images from
    * `min_dimension` — optional minimum pixel dimension filter (default 0)
  """
  @spec perform_export_images(map()) :: :ok | {:error, term()}
  def perform_export_images(args) do
    doc_id = args["doc_id"]
    min_dim = Map.get(args, "min_dimension", 0)

    with {:ok, doc} <- fetch_document(doc_id),
         {:ok, rev} <- Quire.Documents.current_revision(doc),
         %Quire.Storage.Ref{} = ref <- Revision.storage_ref(rev),
         {:ok, images} <- Quire.Render.extract_images(ref, []) do
      filtered =
        if min_dim > 0 do
          filter_by_min_dimension(images, min_dim)
        else
          images
        end

      # Download each image PNG from storage and build ZIP entries.
      zip_entries =
        filtered
        |> Enum.map(fn {page, img_idx, img_ref} ->
          {:ok, png_bytes} = Quire.Storage.get(img_ref)
          filename = ~c"page_#{page + 1}_img_#{img_idx + 1}.png"
          {filename, png_bytes}
        end)

      # Build an in-memory ZIP archive.
      {:ok, {_zip_name, zip_bytes}} =
        :zip.create(~c'exported_images.zip', zip_entries, :memory)

      zip_name = "#{doc.title}_images.zip"

      {:ok, zip_ref} =
        Quire.Storage.put(zip_bytes,
          name: zip_name,
          content_type: "application/zip"
        )

      # Broadcast the result so the LiveView can offer the download.
      Phoenix.PubSub.broadcast(
        Quire.PubSub,
        "document:#{doc_id}",
        {:export_images_ready, %{ref: zip_ref, name: zip_name}}
      )

      :ok
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, "no storage ref on current revision"}
    end
  end

  # Filter image triples where the PNG is at least `min_dim` on the shortest side.
  # Reads each image from storage to inspect its dimensions via Vix.
  defp filter_by_min_dimension(images, min_dim) when min_dim > 0 do
    Enum.filter(images, fn {_page, _idx, img_ref} ->
      {:ok, png_bytes} = Quire.Storage.get(img_ref)
      meets_min_dimension?(png_bytes, min_dim)
    end)
  end

  defp filter_by_min_dimension(images, _), do: images

  defp meets_min_dimension?(png_bytes, min_dim) do
    case Vix.Vips.Image.new_from_buffer(png_bytes, "") do
      {:ok, image} ->
        {:ok, w} = Vix.Vips.Image.width(image)
        {:ok, h} = Vix.Vips.Image.height(image)
        min(w, h) >= min_dim

      {:error, _} ->
        # If we can't read the image, keep it anyway
        true
    end
  end

  # ── Page and text cache copy ──────────────────────────────────────────

  @doc ~S"""
  Copy `document_pages` and `document_page_text` rows from the old revision
  to the new revision using a page-preservation map.

  `preserved_map` maps each new-revision page index to the old-revision page
  index whose content is preserved (so cache data — geometry, thumbnail ref,
  text — can be carried forward).  Pages whose value is `nil` are genuinely
  new (blank insert, replacement page) and receive minimal placeholder rows.

  When any placeholder rows are inserted, the caller is expected to enqueue
  a `TextExtractWorker` job to populate them with real extracted text.
  """
  @spec copy_page_caches(
          repo :: Ecto.Repo.t(),
          old_revision_id :: binary(),
          new_revision_id :: binary(),
          preserved_map :: %{non_neg_integer() => non_neg_integer() | nil}
        ) :: :ok
  def copy_page_caches(repo, old_revision_id, new_revision_id, preserved_map \\ %{}) do
    now = DateTime.utc_now()

    # Carry forward preserved page rows.
    preserved_entries =
      preserved_map
      |> Enum.reject(fn {_new, old} -> is_nil(old) end)
      |> Enum.map(fn {new_idx, old_idx} -> {new_idx, old_idx} end)

    if preserved_entries != [] do
      carry_forward_page_rows(repo, old_revision_id, new_revision_id, preserved_entries, now)
      carry_forward_text_rows(repo, old_revision_id, new_revision_id, preserved_entries, now)
    end

    # Insert minimal rows for genuinely new pages.
    new_indices =
      preserved_map
      |> Enum.filter(fn {_new, old} -> is_nil(old) end)
      |> Enum.map(fn {new_idx, _old} -> new_idx end)
      |> Enum.sort()

    if new_indices != [] do
      insert_minimal_page_rows(repo, new_revision_id, new_indices, now)
      insert_minimal_text_rows(repo, new_revision_id, new_indices, now)
    end

    :ok
  end

  # Carry forward `document_pages` rows for preserved pages with index
  # remapping.  `entries` is a list of `{new_page_index, old_page_index}`.
  defp carry_forward_page_rows(repo, old_rev_id, new_rev_id, entries, now) do
    old_indices = Enum.map(entries, fn {_new, old} -> old end)

    old_rows =
      repo.all(
        from(p in Page,
          where: p.revision_id == ^old_rev_id and p.page_index in ^old_indices,
          select: %{
            page_index: p.page_index,
            width: p.width,
            height: p.height,
            has_text: p.has_text,
            thumbnail_ref: p.thumbnail_ref
          }
        )
      )

    old_by_idx = Map.new(old_rows, fn r -> {r.page_index, r} end)

    new_rows =
      Enum.map(entries, fn {new_idx, old_idx} ->
        old = Map.fetch!(old_by_idx, old_idx)

        %{
          revision_id: new_rev_id,
          page_index: new_idx,
          width: old.width,
          height: old.height,
          has_text: old.has_text,
          thumbnail_ref: old.thumbnail_ref,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo.insert_all(Page, new_rows)
    :ok
  end

  # Carry forward `document_page_text` rows for preserved pages.
  defp carry_forward_text_rows(repo, old_rev_id, new_rev_id, entries, now) do
    old_indices = Enum.map(entries, fn {_new, old} -> old end)

    old_rows =
      repo.all(
        from(pt in PageText,
          where: pt.revision_id == ^old_rev_id and pt.page_index in ^old_indices,
          select: %{page_index: pt.page_index, content: pt.content, spans: pt.spans}
        )
      )

    old_by_idx = Map.new(old_rows, fn r -> {r.page_index, r} end)

    new_rows =
      Enum.map(entries, fn {new_idx, old_idx} ->
        case Map.fetch(old_by_idx, old_idx) do
          {:ok, old} ->
            %{
              revision_id: new_rev_id,
              page_index: new_idx,
              content: old.content,
              spans: old.spans,
              inserted_at: now
            }

          :error ->
            # No text row existed for this page in the old revision.
            %{
              revision_id: new_rev_id,
              page_index: new_idx,
              content: "",
              spans: nil,
              inserted_at: now
            }
        end
      end)

    repo.insert_all(PageText, new_rows)
    :ok
  end

  # Insert minimal `document_pages` rows for genuinely new pages.
  defp insert_minimal_page_rows(repo, rev_id, indices, now) do
    rows =
      Enum.map(indices, fn idx ->
        %{
          revision_id: rev_id,
          page_index: idx,
          width: nil,
          height: nil,
          has_text: false,
          thumbnail_ref: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo.insert_all(Page, rows)
    :ok
  end

  # Insert minimal `document_page_text` rows for genuinely new pages.
  defp insert_minimal_text_rows(repo, rev_id, indices, now) do
    rows =
      Enum.map(indices, fn idx ->
        %{
          revision_id: rev_id,
          page_index: idx,
          content: "",
          spans: nil,
          inserted_at: now
        }
      end)

    repo.insert_all(PageText, rows)
    :ok
  end

  # ── Sidecar index remapping ────────────────────────────────────────────

  @doc ~S"""
  Remap `page_index` in sidecar tables (e.g. annotations) when pages have
  been inserted, deleted, reordered, or extracted.

  Reads annotation rows from the old revision and inserts copies into the
  new revision with remapped page indices derived from `preserved_map`.

  `preserved_map` maps new-revision page indices to the old-revision page
  indices whose content is preserved; `nil` entries (genuinely new pages)
  have no annotation to copy.
  """
  @spec remap_sidecar_indices(
          repo :: Ecto.Repo.t(),
          old_revision_id :: binary(),
          new_revision_id :: binary(),
          preserved_map :: %{non_neg_integer() => non_neg_integer() | nil}
        ) :: :ok
  def remap_sidecar_indices(repo, old_revision_id, new_revision_id, preserved_map \\ %{}) do
    # Build inverse map: old_index -> new_index
    old_to_new =
      preserved_map
      |> Enum.reject(fn {_new, old} -> is_nil(old) end)
      |> Map.new(fn {new_idx, old_idx} -> {old_idx, new_idx} end)

    if map_size(old_to_new) > 0 do
      # Fetch all annotations for the old revision.
      old_annotations =
        repo.all(
          from(a in Annotation,
            where: a.revision_id == ^old_revision_id
          )
        )

      old_by_page = Enum.group_by(old_annotations, & &1.page_index)
      now = DateTime.utc_now()

      new_rows =
        Enum.flat_map(old_to_new, fn {old_idx, new_idx} ->
          case Map.fetch(old_by_page, old_idx) do
            {:ok, annots} ->
              Enum.map(annots, fn a ->
                %{
                  revision_id: new_revision_id,
                  page_index: new_idx,
                  kind: a.kind,
                  quad_points: a.quad_points,
                  color: a.color,
                  opacity: a.opacity,
                  content: a.content,
                  inserted_at: now,
                  updated_at: now
                }
              end)

            :error ->
              []
          end
        end)

      if new_rows != [] do
        repo.insert_all(Annotation, new_rows)
      end
    end

    :ok
  end

  # ── Preserved-page map computation ─────────────────────────────────────

  # Build a map from each new page index to the old page index whose content
  # is preserved, or `nil` for genuinely new pages.
  #
  # Page-preserving operations (rotate, background, size/margin): all pages
  # stay at the same index — identity map.

  defp compute_preserved_map("rotate", args, _old_page_count) do
    page_order = Map.get(args, "page_order", [])
    Map.new(page_order, fn idx -> {idx, idx} end)
  end

  defp compute_preserved_map("crop", args, _old_page_count) do
    page_order = Map.get(args, "page_order", [])
    Map.new(page_order, fn idx -> {idx, idx} end)
  end

  defp compute_preserved_map("remove_crop", args, _old_page_count) do
    page_order = Map.get(args, "page_order", [])
    Map.new(page_order, fn idx -> {idx, idx} end)
  end

  defp compute_preserved_map("background", _args, old_page_count) do
    Map.new(0..(old_page_count - 1), fn i -> {i, i} end)
  end

  defp compute_preserved_map("page_size_margin", args, _old_page_count) do
    page_order = Map.get(args, "page_order", [])
    Map.new(page_order, fn idx -> {idx, idx} end)
  end

  # Insert: pages before `position` are preserved at the same index; the
  # blank page at `position` is new (nil); subsequent pages are shifted
  # right by one (old_idx → new_idx + 1).
  defp compute_preserved_map("insert_blank", args, old_page_count) do
    position = Map.get(args, "position", 0)

    preserved_before = Map.new(0..(position - 1), fn i -> {i, i} end)
    blank = %{position => nil}

    shifted =
      position..(old_page_count - 1)
      |> Enum.with_index(position + 1)
      |> Map.new(fn {old_idx, new_idx} -> {new_idx, old_idx} end)

    preserved_before |> Map.merge(blank) |> Map.merge(shifted)
  end

  # Extract: kept pages from page_order, preserving content at new indices.
  defp compute_preserved_map("extract", args, _old_page_count) do
    page_order = Map.get(args, "page_order", [])
    Map.new(Enum.with_index(page_order), fn {old_idx, new_idx} -> {new_idx, old_idx} end)
  end

  # Replace: pages before `insert_at` are identity; replacement pages at
  # `insert_at` are nil; kept pages after the replacement are shifted right.
  defp compute_preserved_map("replace", args, _old_page_count) do
    page_order = Map.get(args, "page_order", [])
    insert_at = Map.get(args, "insert_at", 0)
    repl_count = replacement_page_count(args)
    kept_after = max(length(page_order) - insert_at, 0)

    before = Map.new(0..(insert_at - 1), fn i -> {i, i} end)
    new_pages = Map.new(insert_at..(insert_at + repl_count - 1), fn i -> {i, nil} end)

    shifted =
      Enum.map(insert_at..(insert_at + kept_after - 1), fn i ->
        new_idx = insert_at + repl_count + (i - insert_at)
        {new_idx, page_order[i]}
      end)
      |> Map.new()

    before |> Map.merge(new_pages) |> Map.merge(shifted)
  end

  # Fallback for delete, reverse, page_splice, and other splice-based ops:
  # the page_order directly maps new positions to old source indices.
  defp compute_preserved_map(_op, args, _old_page_count) do
    page_order = Map.get(args, "page_order", [])
    Map.new(Enum.with_index(page_order), fn {old_idx, new_idx} -> {new_idx, old_idx} end)
  end

  # Count pages in the replacement PDF (base64-encoded in the job args).
  defp replacement_page_count(args) do
    case Map.get(args, "replacement_bytes") do
      nil ->
        0

      b64 when is_binary(b64) ->
        bytes = Base.decode64!(b64)

        case ExPdfium.open_blob(bytes) do
          {:ok, doc} ->
            count =
              case ExPdfium.page_count(doc) do
                {:ok, n} -> n
                _ -> 1
              end

            ExPdfium.close(doc)
            count

          _ ->
            1
        end
    end
  end

  defp operation_label("page_size_margin"), do: "Page size & margin"
  defp operation_label("crop"), do: "Page crop"
  defp operation_label("remove_crop"), do: "Remove crop"
  defp operation_label("background"), do: "Page background"
  defp operation_label("page_splice"), do: "Page splice"
  defp operation_label("insert_blank"), do: "Insert blank page"
  defp operation_label("extract"), do: "Extract pages"
  defp operation_label("replace"), do: "Replace pages"
  defp operation_label("delete"), do: "Delete pages"
  defp operation_label("reverse"), do: "Reverse pages"
  defp operation_label("rotate"), do: "Rotate pages"
  defp operation_label(op), do: "Page operation: #{op}"
end
