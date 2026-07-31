defmodule Quire.Pdf.SignatureFlatten do
  @moduledoc """
  Flatten a signature image into a PDF page's content stream as an image
  XObject (plan3.md §9.4, T-115).

  The placed signature becomes part of the page content itself — not an
  annotation — so it survives save/reload, re-render and flattening by any
  other tool. The image is embedded as a `/Subtype /Image` stream with a
  `/SMask` soft mask when the source PNG carries an alpha channel
  (signatures are dark ink on transparent).

  ## Coordinate frame

  `rect` is `[x0, y0, x1, y1]` in **PDF user space** (bottom-left origin,
  points). The client produces it via pdf.js `PageViewport.convertToPdfPoint`
  (through `assets/js/pdf/geometry.js` `cssToPdf/6`), which maps back into the
  page's true user space regardless of `/Rotate` or a non-zero `/CropBox`
  origin. This module places the rect verbatim — no conversion here, matching
  §14.3's "convert at the boundary" rule.
  """

  alias Quire.Pdf

  @typedoc "A placed rect: `[x0, y0, x1, y1]` in PDF user-space points."
  @type rect :: list(number())

  @doc """
  Embed `png_bytes` at `rect` on page `page_index` of `pdf_bytes`.

  Returns the new document bytes. The signature is drawn on top of the
  page's existing content, preserving everything already there.

  ## Options

    * `:name` — XObject resource name (default `"/ImSig1"`). Pass a unique
      name when placing several signatures so their resource names do not
      collide; the page `/Resources /XObject` dictionary is merged, never
      replaced.

  ## Errors

    * `{:error, :invalid_pdf}` — `pdf_bytes` is not a readable PDF
    * `{:error, :page_out_of_bounds}` — `page_index` does not exist
    * `{:error, {:image, reason}}` — `png_bytes` could not be decoded
    * `{:error, :bad_rect}` — `rect` is not four finite numbers
  """
  @spec place(binary(), non_neg_integer(), rect(), binary(), keyword()) ::
          {:ok, binary()} | {:error, atom() | {:image, term()}}
  def place(pdf_bytes, page_index, rect, png_bytes, opts \\ [])
      when is_binary(pdf_bytes) and is_integer(page_index) and page_index >= 0 and
             is_binary(png_bytes) and is_list(opts) do
    name = Keyword.get(opts, :name, "/ImSig1")

    with :ok <- validate_rect(rect),
         {:ok, doc} <- Pdf.open(pdf_bytes),
         {:ok, page_id} <- page_id(doc, page_index),
         {:ok, page} <- Pdf.get_object(doc, page_id),
         {:ok, image} <- decode_png(png_bytes) do
      embed(doc, page_id, page, rect, image, name)
      |> then(fn result ->
        case result do
          :ok ->
            Pdf.save(doc)

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  # ── Page tree walk ──────────────────────────────────────────────────────────

  defp page_id(doc, page_index) do
    with {:ok, catalog} <- Pdf.catalog(doc) do
      case catalog["/Pages"] do
        {:ref, num, gen} ->
          case find_page(doc, {num, gen}, page_index, 0) do
            {:ok, id} -> {:ok, id}
            {:not_found, _leaves} -> {:error, :page_out_of_bounds}
            {:error, reason} -> {:error, reason}
          end

        _ ->
          {:error, :invalid_pdf}
      end
    end
  end

  # Depth-first walk of the page tree returning the `target`-th leaf page
  # (0-based) as `{obj_num, gen_num}`. Returns `:not_found` when the tree is
  # exhausted before reaching the target.
  defp find_page(doc, {num, gen}, target, acc) do
    case Pdf.get_object(doc, {num, gen}) do
      {:ok, dict} ->
        case dict["/Type"] do
          {:name, "Page"} ->
            if acc == target, do: {:ok, {num, gen}}, else: {:not_found, 1}

          {:name, "Pages"} ->
            children = Map.get(dict, "/Kids", [])

            case Map.get(dict, "/Count") do
              count when is_integer(count) ->
                if acc + count > target,
                  do: search_children(children, doc, target, acc),
                  else: {:not_found, count}

              nil ->
                leaves = count_leaves(doc, children, 0)

                if acc + leaves > target,
                  do: search_children(children, doc, target, acc),
                  else: {:not_found, leaves}
            end

          _ ->
            {:error, :invalid_pdf}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Walk the kids of a /Pages node in order, advancing the accumulated page
  # count by each subtree's leaf count, until the target page is found.
  defp search_children([], _doc, _target, _acc), do: {:not_found, 0}

  defp search_children([{:ref, knum, kgen} | rest], doc, target, acc) do
    case find_page(doc, {knum, kgen}, target, acc) do
      {:ok, id} ->
        {:ok, id}

      {:not_found, leaves} ->
        search_children(rest, doc, target, acc + leaves)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp search_children([_other | rest], doc, target, acc),
    do: search_children(rest, doc, target, acc)

  # Number of leaf pages under a list of kids, using /Count when present.
  defp count_leaves(_doc, [], acc), do: acc

  defp count_leaves(doc, [{:ref, knum, kgen} | rest], acc) do
    case Pdf.get_object(doc, {knum, kgen}) do
      {:ok, %{"/Type" => {:name, "Page"}}} ->
        count_leaves(doc, rest, acc + 1)

      {:ok, %{"/Type" => {:name, "Pages"}, "/Count" => count}} when is_integer(count) ->
        count_leaves(doc, rest, acc + count)

      {:ok, %{"/Type" => {:name, "Pages"}} = node} ->
        count_leaves(doc, Map.get(node, "/Kids", []) ++ rest, acc)

      _ ->
        count_leaves(doc, rest, acc)
    end
  end

  defp count_leaves(doc, [_other | rest], acc), do: count_leaves(doc, rest, acc)

  # ── PNG decode via libvips ─────────────────────────────────────────────────

  defp decode_png(png_bytes) do
    with {:ok, img} <- Vix.Vips.Image.new_from_buffer(png_bytes),
         {:ok, srgb} <- Vix.Vips.Operation.colourspace(img, :VIPS_INTERPRETATION_sRGB) do
      w = Vix.Vips.Image.width(srgb)
      h = Vix.Vips.Image.height(srgb)

      case Vix.Vips.Image.bands(srgb) do
        4 ->
          with {:ok, rgb} <- Vix.Vips.Operation.extract_band(srgb, 0, n: 3),
               {:ok, alpha} <- Vix.Vips.Operation.extract_band(srgb, 3),
               {:ok, rgb_raw} <- Vix.Vips.Image.write_to_buffer(rgb, ".raw"),
               {:ok, alpha_raw} <- Vix.Vips.Image.write_to_buffer(alpha, ".raw") do
            {:ok, %{width: w, height: h, rgb: rgb_raw, alpha: alpha_raw}}
          else
            {:error, reason} -> {:error, {:image, reason}}
          end

        3 ->
          with {:ok, rgb_raw} <- Vix.Vips.Image.write_to_buffer(srgb, ".raw") do
            {:ok, %{width: w, height: h, rgb: rgb_raw, alpha: nil}}
          else
            {:error, reason} -> {:error, {:image, reason}}
          end

        bands ->
          {:error, {:image, {:unsupported_bands, bands}}}
      end
    else
      {:error, reason} -> {:error, {:image, reason}}
    end
  end

  # ── Embedding ───────────────────────────────────────────────────────────────

  defp embed(doc, page_id, page, [x0, y0, x1, y1], image, name) do
    w = x1 - x0
    h = y1 - y0

    with {:ok, img_ref} <- write_image_objects(doc, image),
         :ok <- write_content(doc, page_id, page, x0, y0, w, h, name, img_ref) do
      :ok
    end
  end

  defp write_image_objects(doc, %{alpha: nil} = image) do
    with {:ok, img_num} <- Pdf.allocate_object_id(doc),
         :ok <-
           Pdf.set_object(doc, {img_num, 0}, image_stream(image, nil)) do
      {:ok, {:ref, img_num, 0}}
    end
  end

  defp write_image_objects(doc, %{alpha: alpha} = image) when is_binary(alpha) do
    with {:ok, smask_num} <- Pdf.allocate_object_id(doc),
         {:ok, img_num} <- Pdf.allocate_object_id(doc),
         :ok <- Pdf.set_object(doc, {smask_num, 0}, smask_stream(image)),
         :ok <-
           Pdf.set_object(doc, {img_num, 0}, image_stream(image, {:ref, smask_num, 0})) do
      {:ok, {:ref, img_num, 0}}
    end
  end

  defp image_stream(image, smask_ref) do
    dict = %{
      "/Type" => {:name, "XObject"},
      "/Subtype" => {:name, "Image"},
      "/Width" => image.width,
      "/Height" => image.height,
      "/ColorSpace" => {:name, "DeviceRGB"},
      "/BitsPerComponent" => 8,
      "/Filter" => {:name, "FlateDecode"}
    }

    dict = if smask_ref, do: Map.put(dict, "/SMask", smask_ref), else: dict
    {:stream, dict, :zlib.compress(image.rgb)}
  end

  defp smask_stream(image) do
    {:stream,
     %{
       "/Type" => {:name, "XObject"},
       "/Subtype" => {:name, "Image"},
       "/Width" => image.width,
       "/Height" => image.height,
       "/ColorSpace" => {:name, "DeviceGray"},
       "/BitsPerComponent" => 8,
       "/Filter" => {:name, "FlateDecode"}
     }, :zlib.compress(image.alpha)}
  end

  # ── Page content stream ─────────────────────────────────────────────────────

  # Prepend the placement operators to the page content and point /Contents at
  # a fresh stream object, preserving any existing content.
  defp write_content(doc, page_id, page, x, y, w, h, name, img_ref) do
    ops = [
      "q\n",
      "#{fmt(w)} 0 0 #{fmt(h)} #{fmt(x)} #{fmt(y)} cm\n",
      "#{name} Do\n",
      "Q\n"
    ]

    new_data = IO.iodata_to_binary(ops)

    with {:ok, content_id} <- Pdf.allocate_object_id(doc),
         :ok <- Pdf.set_object(doc, {content_id, 0}, {:stream, %{}, new_data}) do
      contents =
        case Map.get(page, "/Contents") do
          nil -> {:ref, content_id, 0}
          {:ref, num, gen} -> [{:ref, num, gen}, {:ref, content_id, 0}]
          list when is_list(list) -> list ++ [{:ref, content_id, 0}]
          _ -> {:ref, content_id, 0}
        end

      updated_page =
        page
        |> Map.put("/Contents", contents)
        |> put_image_resource(doc, name, img_ref)

      Pdf.set_object(doc, page_id, updated_page)
    end
  end

  # Add /XObject to the page's /Resources. /Resources (and its /XObject dict)
  # may be an inline dict or an indirect reference to a shared object — resolve
  # the ref in place and write the update back so other pages keep sharing it.
  defp put_image_resource(page, doc, name, ref) do
    case Map.get(page, "/Resources", %{}) do
      {:ref, rnum, rgen} ->
        case Pdf.get_object(doc, {rnum, rgen}) do
          {:ok, resources} ->
            updated = add_xobject(doc, resources, name, ref)
            :ok = Pdf.set_object(doc, {rnum, rgen}, updated)
            page

          {:error, _reason} ->
            page
        end

      resources when is_map(resources) ->
        Map.put(page, "/Resources", add_xobject(doc, resources, name, ref))
    end
  end

  defp add_xobject(doc, resources, name, ref) do
    case Map.get(resources, "/XObject") do
      {:ref, xnum, xgen} ->
        case Pdf.get_object(doc, {xnum, xgen}) do
          {:ok, xobjects} when is_map(xobjects) ->
            updated = Map.put(xobjects, name, ref)
            :ok = Pdf.set_object(doc, {xnum, xgen}, updated)
            resources

          _ ->
            resources
        end

      xobjects when is_map(xobjects) ->
        Map.put(resources, "/XObject", Map.put(xobjects, name, ref))

      nil ->
        Map.put(resources, "/XObject", %{name => ref})
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp validate_rect([x0, y0, x1, y1])
       when is_number(x0) and is_number(y0) and is_number(x1) and is_number(y1) do
    if x1 > x0 and y1 > y0, do: :ok, else: {:error, :bad_rect}
  end

  defp validate_rect(_), do: {:error, :bad_rect}

  defp fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
end
