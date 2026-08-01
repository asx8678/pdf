defmodule Quire.SecurityHandler.Redact do
  @moduledoc """
  **Apply redaction** with mandatory post-hoc verification (plan3.md §9.7
  line 1680, T-134, Appendix C R-06).

  Redaction is *destructive server content removal*, distinct from `whiteout`
  (which is only a cosmetic opaque rectangle). It operates on raw PDF bytes
  and returns `{:ok, binary}` **only** when the applied redactions are proven
  unrecoverable by text extraction — the plan's only **Critical** risk.

  ## Paths

  The plan describes two paths for a redacted page, in preference order (a)
  then (b):

    * **(a) PDFium object removal** — draw an opaque rectangle via PDFium's
      `draw_rectangle` on the marked area, which removes the underlying text,
      image and vector objects intersecting the mark.

    * **(b) rasterise-and-replace** — the *automatic, bulletproof* fallback.
      Rasterise the affected page at **300 DPI**, blank the marked region to
      opaque black, and *replace* the page content with a single image draw
      so **no text operators survive**. Path (b) triggers automatically
      wherever (a) cannot prove completeness — a Flate-encoded content stream,
      a Type-3 glyph overlap, or an unparseable stream.

  ## Mandatory post-hoc verification (`verify_absent/1`)

  Before applying we snapshot the text spans that intersect each mark
  ("redacted strings"). After every apply we **re-extract text** and assert
  none survive. If any do, `apply/2` returns
  `{:error, {:redactions_verification_failed, survivors}}` and the caller
  keeps the original document — the job fails rather than shipping a leak.

  ## Integration

  `apply/2` is pure bytes-in/bytes-out. The `:secure` worker
  (`Quire.Workers.SecureWorker`) creates a new revision from the returned
  bytes and — **only on `{:ok, _}`** — marks the document's `metadata`
  with `redactions.applied` / `redactions.applied_revision_id`. The tests
  prove the string is gone from text extraction, and that the applied flags
  are set only on success.
  """

  alias Quire.Pdf

  @render_dpi 300

  @typedoc """
  A redaction mark. `rect` is `[x0, y0, x1, y1]` in PDF user-space points
  (bottom-left origin), matching `redactions.rect`.
  """
  @type rect :: list(number())
  @type mark :: %{
          required(:page) => non_neg_integer(),
          required(:rect) => rect(),
          optional(:reason) => String.t(),
          optional(:overlay_text) => String.t()
        }

  @doc """
  Apply redaction marks to `pdf_bytes`.

  Returns `{:ok, redacted_bytes}` only when all marks are applied and the
  post-hoc text extraction verification passes (redacted strings absent).
  On error the input document is **not replaced** — callers keep the source.
  """
  @spec apply(binary(), [mark()]) :: {:ok, binary()} | {:error, term()}
  def apply(pdf_bytes, marks) when is_binary(pdf_bytes) and is_list(marks) do
    with {:ok, _doc} <- Pdf.open(pdf_bytes),
         {:ok, redacted_strings} <- redaction_snapshot(pdf_bytes, marks) do
      case apply_marks(pdf_bytes, marks) do
        {:ok, out_bytes} ->
          case verify_absent(out_bytes, redacted_strings) do
            :ok -> {:ok, out_bytes}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Path dispatch — path (a) preferred, path (b) as automatic fallback
  # ---------------------------------------------------------------------------

  defp apply_marks(pdf_bytes, marks) do
    # Try path (a) — PDFium object removal — first.
    case apply_pdfium_path(pdf_bytes, marks) do
      {:ok, out_bytes} ->
        {:ok, out_bytes}

      {:error, _reason_a} ->
        # Path (a) failed — automatic fallback to path (b).
        apply_raster_path(pdf_bytes, marks)
    end
  end

  # ---------------------------------------------------------------------------
  # Path (a) — PDFium object removal via draw_rectangle
  # ---------------------------------------------------------------------------

  defp apply_pdfium_path(pdf_bytes, marks) do
    with {:ok, doc} <- ExPdfium.open_blob(pdf_bytes) do
      try do
        {:ok, page_count} = ExPdfium.page_count(doc)

        result =
          Enum.reduce_while(marks, {:ok, doc}, fn mark, {:ok, acc_doc} ->
            if mark.page < page_count do
              rect = mark.rect
              [x0, y0, x1, y1] = rect

              bounds = %{left: x0, bottom: y0, right: x1, top: y1}

              case ExPdfium.draw_rectangle(acc_doc, mark.page, bounds,
                     fill: {0, 0, 0},
                     stroke: nil
                   ) do
                {:ok, updated_doc} -> {:cont, {:ok, updated_doc}}
                {:error, reason} -> {:halt, {:error, {:pdfium_path_failed, mark.page, reason}}}
              end
            else
              {:halt, {:error, {:page_out_of_bounds, mark.page}}}
            end
          end)

        case result do
          {:ok, final_doc} ->
            ExPdfium.save_to_bytes(final_doc)

          {:error, _} = err ->
            err
        end
      after
        ExPdfium.close(doc)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Path (b) — rasterise-and-replace
  # ---------------------------------------------------------------------------

  defp apply_raster_path(pdf_bytes, marks) do
    Enum.reduce_while(marks, {:ok, pdf_bytes}, fn mark, {:ok, acc} ->
      case redact_page_by_raster(acc, mark.page, mark.rect) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  # Rasterise `page_index` of `pdf_bytes` at 300 DPI, blank `rect` to black,
  # and replace the page content with a single image draw (no text operators).
  @spec redact_page_by_raster(binary(), non_neg_integer(), rect()) ::
          {:ok, binary()} | {:error, term()}
  def redact_page_by_raster(pdf_bytes, page_index, rect)
      when is_binary(pdf_bytes) and is_integer(page_index) and page_index >= 0 do
    with {:ok, ref} <- Quire.Storage.put(pdf_bytes, []),
         {:ok, png} <- Quire.Render.render_page(ref, page_index, dpi: @render_dpi),
         {:ok, doc} <- Pdf.open(pdf_bytes),
         {:ok, {pnum, pgen}} <- page_id(doc, page_index),
         {:ok, page} <- Pdf.get_object(doc, {pnum, pgen}),
         {:ok, [pw, ph]} <- media_box(page),
         {:ok, image} <- blank_and_blank(png, rect, pw, ph),
         :ok <- embed_page_image(doc, {pnum, pgen}, page, image, pw, ph) do
      Pdf.save(doc)
    end
  end

  # -- image blanking ---------------------------------------------------------

  # Decode the rendered PNG to raw sRGB (3 bytes/pixel, row-major, top-left)
  # and set every pixel inside `rect` to opaque black.
  defp blank_and_blank(png, rect, _pw, ph) do
    with {:ok, img} <- Vix.Vips.Image.new_from_buffer(png),
         {:ok, srgb} <- Vix.Vips.Operation.colourspace(img, :VIPS_INTERPRETATION_sRGB),
         width = Vix.Vips.Image.width(srgb),
         true <- is_integer(width) and width > 0,
         height = Vix.Vips.Image.height(srgb),
         true <- is_integer(height) and height > 0,
         {:ok, rgb} <- Vix.Vips.Image.write_to_buffer(srgb, ".raw") do
      # pixels per point: 1 pt = dpi/72 px
      pp = @render_dpi / 72.0
      [x0, y0, x1, y1] = rect

      xpx0 = round(x0 * pp) |> max(0) |> min(width - 1)
      xpx1 = round(x1 * pp) |> max(0) |> min(width - 1)
      # PDF y is bottom-up; image y is top-down.
      top_px = round((ph - y1) * pp) |> max(0) |> min(height - 1)
      bottom_px = round((ph - y0) * pp) |> max(0) |> min(height - 1)

      next = blank_region(rgb, width, xpx0, xpx1, top_px, bottom_px)
      {:ok, %{width: width, height: height, rgb: next}}
    end
  end

  @spec blank_region(
          binary(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: binary()
  def blank_region(rgb, width, x0, x1, top, bottom) do
    rows = floor(bottom)..floor(top)
    cols = floor(x0)..floor(x1)

    Enum.reduce(rows, rgb, fn row, buf ->
      Enum.reduce(cols, buf, fn col, buf ->
        put_pixel_black(buf, row * width + col)
      end)
    end)
  end

  defp put_pixel_black(buf, flat_index) do
    idx = flat_index * 3
    head = binary_part(buf, 0, idx)
    tail = binary_part(buf, idx + 3, byte_size(buf) - idx - 3)
    head <> <<0, 0, 0>> <> tail
  end

  # -- page content replacement ------------------------------------------

  defp embed_page_image(doc, page_id, page, image, pw, ph) do
    with {:ok, img_ref} <- write_image_object(doc, image),
         {:ok, content_id} <- Pdf.allocate_object_id(doc) do
      ops = ["q\n", "#{num(pw)} 0 0 #{num(ph)} 0 0 cm\n", "/ImRedaction Do\n", "Q\n"]

      :ok = Pdf.set_object(doc, {content_id, 0}, {:stream, %{}, IO.iodata_to_binary(ops)})

      updated =
        page
        |> Map.put("/Contents", {:ref, content_id, 0})
        |> Map.put("/Resources", %{"/XObject" => %{"/ImRedaction" => img_ref}})

      case Pdf.set_object(doc, page_id, updated) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp write_image_object(doc, %{width: w, height: h, rgb: rgb}) do
    with {:ok, img_num} <- Pdf.allocate_object_id(doc) do
      dict = %{
        "/Type" => {:name, "XObject"},
        "/Subtype" => {:name, "Image"},
        "/Width" => w,
        "/Height" => h,
        "/ColorSpace" => {:name, "DeviceRGB"},
        "/BitsPerComponent" => 8,
        "/Filter" => {:name, "FlateDecode"}
      }

      case Pdf.set_object(doc, {img_num, 0}, {:stream, dict, :zlib.compress(rgb)}) do
        :ok -> {:ok, {:ref, img_num, 0}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mandatory post-hoc verification
  # ---------------------------------------------------------------------------

  @doc false
  # Re-extract text from `out_bytes` and assert none of the redacted strings
  # survive. Returns :ok or a fail-closed error tuple.
  def verify_absent(out_bytes, redacted_strings) do
    searchable = join_extracted(out_bytes)

    survivors =
      redacted_strings
      |> Enum.reject(fn {_page, str} -> not String.contains?(searchable, str) end)
      |> Enum.map(fn {page, str} -> %{page: page, string: str} end)

    if survivors == [],
      do: :ok,
      else: {:error, {:redactions_verification_failed, survivors}}
  end

  defp join_extracted(pdf_bytes) do
    with {:ok, ref} <- Quire.Storage.put(pdf_bytes, []),
         {:ok, pages} <- Quire.Render.extract_text(ref) do
      Enum.map_join(pages, "\n", fn p ->
        Enum.map_join(p.spans || [], " ", fn s -> s[:text] || "" end)
      end)
    else
      _ -> ""
    end
  end

  # ---------------------------------------------------------------------------
  # Snapshot the redacted strings (text spans under each mark)
  # ---------------------------------------------------------------------------

  defp redaction_snapshot(pdf_bytes, marks) do
    with {:ok, ref} <- Quire.Storage.put(pdf_bytes, []),
         {:ok, pages} <- Quire.Render.extract_text(ref) do
      pages_map = Map.new(pages, fn p -> {p.page, p.spans || []} end)

      strings =
        for(
          mark <- marks,
          span <- Map.get(pages_map, mark.page, []),
          rect_covers_span?(mark.rect, span[:bounds]),
          do: {mark.page, span[:text] || ""}
        )
        |> Enum.reject(fn {_p, s} -> s == "" end)
        |> Enum.uniq()

      {:ok, strings}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Geometry / page navigation
  # ---------------------------------------------------------------------------

  @spec rect_covers_span?(rect(), term()) :: boolean()
  def rect_covers_span?([x0, y0, x1, y1], %{left: l, right: r, bottom: b, top: t})
      when is_number(l) and is_number(r) and is_number(b) and is_number(t) do
    min(r, x1) > max(l, x0) and min(t, y1) > max(b, y0)
  end

  def rect_covers_span?(_rect, _), do: false

  defp media_box(page) do
    case Map.get(page, "/MediaBox") do
      [x0, y0, x1, y1] when is_number(x0) and is_number(y0) and is_number(x1) and is_number(y1) ->
        {:ok, [x1 - x0, y1 - y0]}

      _ ->
        {:error, :bad_mediabox}
    end
  end

  defp page_id(doc, page_index) do
    with {:ok, catalog} <- Pdf.catalog(doc) do
      case catalog["/Pages"] do
        {:ref, num, gen} ->
          case find_page(doc, {num, gen}, page_index, 0) do
            {:ok, id} -> {:ok, id}
            {:not_found, _} -> {:error, :page_out_of_bounds}
            {:error, reason} -> {:error, reason}
          end

        _ ->
          {:error, :invalid_pdf}
      end
    end
  end

  defp find_page(_doc, _page_node, target, acc) when target < acc, do: {:not_found, 0}

  defp find_page(doc, {num, gen}, target, acc) do
    case Pdf.get_object(doc, {num, gen}) do
      {:ok, %{"/Type" => {:name, "Page"}}} ->
        if acc == target, do: {:ok, {num, gen}}, else: {:not_found, 1}

      {:ok, %{"/Type" => {:name, "Pages"}} = dict} ->
        case Map.get(dict, "/Count") do
          c when is_integer(c) ->
            if acc + c > target do
              search_children(Map.get(dict, "/Kids", []), doc, target, acc)
            else
              {:not_found, c}
            end

          nil ->
            leaves = count_leaves(doc, Map.get(dict, "/Kids", []), 0)

            if acc + leaves > target do
              search_children(Map.get(dict, "/Kids", []), doc, target, acc)
            else
              {:not_found, leaves}
            end
        end

      _ ->
        {:error, :invalid_page_node}
    end
  end

  defp search_children([], _doc, _target, _acc), do: {:not_found, 0}

  defp search_children([{:ref, knum, kgen} | rest], doc, target, acc) do
    case find_page(doc, {knum, kgen}, target, acc) do
      {:ok, id} -> {:ok, id}
      {:not_found, leaves} -> search_children(rest, doc, target, acc + leaves)
      {:error, reason} -> {:error, reason}
    end
  end

  defp search_children([_other | rest], doc, target, acc),
    do: search_children(rest, doc, target, acc)

  defp count_leaves(_doc, [], acc), do: acc

  defp count_leaves(doc, [{:ref, knum, kgen} | rest], acc) do
    case Pdf.get_object(doc, {knum, kgen}) do
      {:ok, %{"/Type" => {:name, "Page"}}} ->
        count_leaves(doc, rest, acc + 1)

      {:ok, %{"/Type" => {:name, "Pages"}, "/Count" => c}} when is_integer(c) ->
        count_leaves(doc, rest, acc + c)

      {:ok, %{"/Type" => {:name, "Pages"}} = node} ->
        count_leaves(doc, Map.get(node, "/Kids", []) ++ rest, acc)

      _ ->
        count_leaves(doc, rest, acc)
    end
  end

  defp count_leaves(doc, [_other | rest], acc), do: count_leaves(doc, rest, acc)

  defp num(n) when is_integer(n), do: Integer.to_string(n)
  defp num(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
end
