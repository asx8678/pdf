defmodule Quire.Compress do
  @moduledoc ~S"""
  Compress a PDF by recompressing its embedded images (§9.2, T-083).

  Pipeline:

    1. Enumerate embedded image XObjects via PDFium (`ExPdfium.images/2` +
       `image_data/3` → raw pixels).
    2. Downscale and re-encode each image via vix (libvips) as JPEG at the
       preset's quality.
    3. Normalise the document through PDFium, then replace each image
       XObject's stream in place via `Quire.Pdf.set_object/3` using
       `{:stream, dict, data}`.
    4. Rebuild via `Quire.Pdf.save_with/2` with object streams and
       cross-reference streams (linearization is deliberately not produced —
       ADR 0003 scope reduction).

  `/StructTreeRoot` and `/MarkInfo` are never touched unless the explicit
  `remove_accessibility: true` opt-in is set — tagged-PDF accessibility is
  preserved by default.

  Presets:

    * `:low`    — quality 85, downscale to at most 4096 px
    * `:medium` — quality 70, downscale to at most 2048 px
    * `:high`   — quality 50, downscale to at most 1024 px
    * `:custom` — `quality:` and `max_width:` options

  Everything runs on in-memory buffers (T-014 guard).
  """

  alias Quire.Pdf
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  @presets %{
    low: %{quality: 85, max_width: 4096},
    medium: %{quality: 70, max_width: 2048},
    high: %{quality: 50, max_width: 1024}
  }

  @type preset :: :low | :medium | :high | :custom

  @doc """
  Returns the preset parameters: `%{quality: 0..100, max_width: pos_integer}`.
  `:custom` is resolved from `opts` (`:quality`, `:max_width`).
  """
  @spec preset_params(preset(), keyword()) :: %{quality: pos_integer(), max_width: pos_integer()}
  def preset_params(:custom, opts) do
    %{
      quality: Keyword.get(opts, :quality, 60),
      max_width: Keyword.get(opts, :max_width, 2048)
    }
  end

  def preset_params(preset, _opts) when is_atom(preset) do
    Map.fetch!(@presets, preset)
  end

  @doc """
  Compresses a PDF.

  Options:

    * `:preset` — `:low | :medium | :high | :custom` (default `:medium`)
    * `:quality` / `:max_width` — for `:custom`
    * `:remove_accessibility` — `boolean()`, default `false`; when `true`,
      strips `/StructTreeRoot` and `/MarkInfo` (explicit opt-in)

  Returns `{:ok, compressed_bytes}` or `{:error, reason}`.
  """
  @spec compress(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def compress(bytes, opts \\ []) when is_binary(bytes) do
    preset = Keyword.get(opts, :preset, :medium)
    params = preset_params(preset, opts)
    strip_a11y? = Keyword.get(opts, :remove_accessibility, false)

    with {:ok, replacements} <- recompress_images(bytes, params),
         {:ok, normalized} <- normalize(bytes),
         {:ok, q} <- Pdf.open(normalized),
         :ok <- replace_streams(q, replacements),
         :ok <- maybe_strip_accessibility(q, strip_a11y?),
         {:ok, out} <-
           Pdf.save_with(q, use_object_streams: true, use_xref_streams: true) do
      {:ok, out}
    end
  end

  # ── Step 1+2: enumerate images and recompress via vix ─────────────────

  defp recompress_images(bytes, params) do
    with {:ok, doc} <- ExPdfium.open(bytes),
         {:ok, count} <- ExPdfium.page_count(doc) do
      result =
        Enum.reduce_while(0..(count - 1), {:ok, []}, fn page, {:ok, acc} ->
          with {:ok, images} <- ExPdfium.images(doc, page),
               {:ok, page_imgs} <- recompress_page(doc, page, images, params) do
            {:cont, {:ok, acc ++ page_imgs}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        {:ok, replacements} -> {:ok, replacements}
        {:error, _} = err -> err
      end
    end
  end

  defp recompress_page(doc, page, images, params) do
    Enum.reduce_while(images, {:ok, []}, fn meta, {:ok, acc} ->
      with {:ok, bitmap} <- ExPdfium.image_data(doc, page, meta.index),
           {:ok, jpeg} <- recompress_bitmap(bitmap, params) do
        {:cont,
         {:ok,
          acc ++
            [
              %{
                page: page,
                index: meta.index,
                width: meta.width,
                height: meta.height,
                jpeg: jpeg
              }
            ]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp recompress_bitmap(%ExPdfium.Bitmap{} = bitmap, params) do
    width = bitmap.width
    height = bitmap.height

    with {:ok, img} <- bitmap_to_vips(bitmap),
         {:ok, img} <- maybe_downscale(img, width, height, params.max_width),
         {:ok, srgb} <- to_srgb(img) do
      encode_jpeg(srgb, params.quality)
    end
  end

  defp bitmap_to_vips(%ExPdfium.Bitmap{} = bitmap) do
    {bands, format} = bitmap_format(bitmap.format)

    if bands == 0 do
      {:error, {:unsupported_image_format, bitmap.format}}
    else
      Image.new_from_binary(bitmap.data, bitmap.width, bitmap.height, bands, format)
    end
  end

  # ExPdfium bitmap formats → {bands, vips format}
  defp bitmap_format(:gray), do: {1, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(:rgb), do: {3, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(:bgr), do: {3, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(:rgba), do: {4, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(:bgrx), do: {4, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(:cmyk), do: {4, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(:lab), do: {3, :VIPS_FORMAT_UCHAR}
  defp bitmap_format(_), do: {0, nil}

  defp maybe_downscale(img, width, _height, max_width) when width <= max_width do
    {:ok, img}
  end

  defp maybe_downscale(img, width, _height, max_width) do
    Operation.resize(img, max_width / width)
  end

  defp to_srgb(%Image{} = img) do
    Operation.colourspace(img, :VIPS_INTERPRETATION_sRGB)
  end

  defp encode_jpeg(srgb, quality) do
    # libvips names the JPEG quality option "Q" (capital)
    with {:ok, jpeg} <- Image.write_to_buffer(srgb, ".jpg", Q: quality) do
      {:ok, jpeg}
    end
  end

  # ── Step 3: normalise through PDFium so lopdf can parse the result ────

  defp normalize(bytes) do
    with {:ok, doc} <- ExPdfium.open(bytes) do
      ExPdfium.save_to_bytes(doc)
    end
  end

  # ── Step 4: replace image XObject streams ──────────────────────────────

  # Walks each page's /Resources /XObject dict, collects Image XObjects in
  # dict order and pairs them with the recompressed JPEGs (matched by page
  # and, within a page, by (width, height) — falling back to order).
  defp replace_streams(q, replacements) do
    with {:ok, catalog} <- Pdf.get_object(q, 1) do
      page_xobjects =
        catalog
        |> collect_pages(q)
        |> Enum.with_index()
        |> Enum.map(fn {{obj, gen}, page} -> {page, image_xobjects(q, obj, gen)} end)

      grouped = Enum.group_by(replacements, & &1.page)

      Enum.reduce_while(grouped, :ok, fn {page, imgs}, :ok ->
        xobjects = page_xobjects_for(page_xobjects, page)

        {:ok, pairs} = pair_images(xobjects, imgs)

        case replace_all(q, pairs) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp page_xobjects_for(page_xobjects, page) do
    case List.keyfind(page_xobjects, page, 0) do
      {^page, xobjects} -> xobjects
      nil -> []
    end
  end

  # Collects page object refs by walking /Pages /Kids (returns refs in page
  # order — page 0 first).
  defp collect_pages(catalog, q) do
    case Map.get(catalog, "/Pages") do
      {:ref, pages_obj, _} -> walk_pages(q, pages_obj)
      _ -> []
    end
  end

  defp walk_pages(q, obj_num) do
    case Pdf.get_object(q, obj_num) do
      {:ok, node} ->
        case Map.get(node, "/Kids") do
          kids when is_list(kids) ->
            Enum.flat_map(kids, fn
              {:ref, child, gen} ->
                case Map.get(node_dict(q, child), "/Type") do
                  {:name, "Pages"} -> walk_pages(q, child)
                  _ -> [{child, gen}]
                end

              _ ->
                []
            end)

          {:ref, child, gen} ->
            [{child, gen}]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp node_dict(q, obj) do
    case Pdf.get_object(q, obj) do
      {:ok, dict} -> dict
      _ -> %{}
    end
  end

  # Returns [{obj, gen, dict}] for Image XObjects in /Resources /XObject,
  # in dict order.
  defp image_xobjects(q, page_obj, page_gen) do
    with {:ok, page} <- Pdf.get_object(q, {page_obj, page_gen}),
         {:ok, resources} <- resolve_resources(q, Map.get(page, "/Resources")),
         {:ok, xobjects} <- resolve_xobjects(q, Map.get(resources, "/XObject")) do
      Enum.filter(xobjects, fn {_name, _obj, _gen, dict} ->
        Map.get(dict, "/Subtype") == {:name, "Image"}
      end)
    else
      _ -> []
    end
  end

  defp resolve_resources(_q, nil), do: {:ok, %{}}

  defp resolve_resources(q, {:ref, obj, gen}) do
    Pdf.get_object(q, {obj, gen})
  end

  defp resolve_resources(_q, dict) when is_map(dict), do: {:ok, dict}

  defp resolve_xobjects(_q, nil), do: {:ok, []}

  defp resolve_xobjects(q, {:ref, obj, gen}) do
    Pdf.get_object(q, {obj, gen})
  end

  defp resolve_xobjects(q, dict) when is_map(dict) do
    dict
    |> Map.to_list()
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, "/") end)
    |> Enum.reduce({:ok, []}, fn {name, {:ref, obj, gen}}, {:ok, acc} ->
      case Pdf.get_object(q, {obj, gen}) do
        {:ok, {:stream, dict, _data}} -> {:ok, acc ++ [{name, obj, gen, dict}]}
        {:ok, dict} when is_map(dict) -> {:ok, acc ++ [{name, obj, gen, dict}]}
        _ -> {:ok, acc}
      end
    end)
  end

  defp resolve_xobjects(_q, _other), do: {:ok, []}

  # Pairs recompressed JPEGs with XObjects for one page, matching by
  # (width, height) where possible, else by dict order.
  defp pair_images(xobjects, images) do
    by_dim = Enum.group_by(images, fn %{width: w, height: h} -> {w, h} end)
    dims_used = MapSet.new()

    {matched, dims_used} =
      Enum.reduce(xobjects, {[], dims_used}, fn {_name, obj, gen, dict}, {acc, used} ->
        dim = xobject_dim(dict)

        case Map.get(by_dim, dim) do
          [img | _] -> {[{obj, gen, dict, img.jpeg} | acc], MapSet.put(used, dim)}
          _ -> {acc, used}
        end
      end)

    matched = Enum.reverse(matched)

    # Any XObject that could not be matched by dimensions gets the remaining
    # JPEGs in dict order.
    remaining =
      Enum.filter(images, fn %{width: w, height: h} -> not MapSet.member?(dims_used, {w, h}) end)

    {ordered, _} =
      Enum.map_reduce(xobjects, remaining, fn {_name, obj, gen, dict}, rem ->
        case List.keyfind(matched, obj, 0) do
          {^obj, _g, _d, jpeg} ->
            {{obj, gen, dict, jpeg}, rem}

          nil ->
            case rem do
              [%{jpeg: jpeg} | rest] -> {{obj, gen, dict, jpeg}, rest}
              [] -> {{obj, gen, dict, nil}, []}
            end
        end
      end)

    {:ok, Enum.filter(ordered, fn {_, _, _, jpeg} -> not is_nil(jpeg) end)}
  end

  defp xobject_dim(dict) do
    {Map.get(dict, "/Width", 0), Map.get(dict, "/Height", 0)}
  end

  defp replace_all(q, pairs) do
    Enum.reduce_while(pairs, :ok, fn {obj, gen, dict, jpeg}, :ok ->
      case replace_stream(q, obj, gen, dict, jpeg) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp replace_stream(q, obj, gen, dict, jpeg) do
    bands =
      case Map.get(dict, "/ColorSpace") do
        {:name, "DeviceGray"} -> 1
        _ -> 3
      end

    new_dict =
      dict
      |> Map.drop(["/Length", "/DecodeParms", "/Filter"])
      |> Map.put("/Filter", {:name, "DCTDecode"})
      |> Map.put("/ColorSpace", {:name, if(bands == 1, do: "DeviceGray", else: "DeviceRGB")})
      |> Map.put("/BitsPerComponent", 8)

    case Pdf.set_object(q, {obj, gen}, {:stream, new_dict, jpeg}) do
      :ok -> :ok
      other -> other
    end
  end

  # ── Accessibility preservation ─────────────────────────────────────────

  defp maybe_strip_accessibility(_q, false), do: :ok

  defp maybe_strip_accessibility(q, true) do
    with {:ok, catalog} <- Pdf.get_object(q, 1) do
      catalog =
        catalog
        |> Map.delete("/StructTreeRoot")
        |> Map.delete("/MarkInfo")

      Pdf.set_object(q, 1, catalog)
    end
  end
end
