defmodule Quire.Scan do
  @moduledoc ~S"""
  Scan-to-PDF pipeline (§9.2, T-080): image bytes → optional deskew → optional
  contrast preset → single-page PDF.

  Everything runs in-memory over Vix (libvips) and ExPdfium: there is no
  filesystem access and no OS scanner driver is ever invoked (§1.2 non-goal),
  which keeps the T-014 `Quire.Checks.NoFileOps` guard green.

  ## Deskew

  Server-side skew correction implemented with vix:

    1. downscale the grayscale image to at most `@hough_max_side` px
    2. `Vix.Vips.Operation.canny/1` for edges
    3. Hough transform over line normals in [45°, 135°] — the half-plane of
       near-horizontal lines (text baselines, page top/bottom edges)
    4. coarse 1° pass, then a 0.1° refinement around the peak
    5. `Vix.Vips.Operation.similarity/2` rotation about the centre with a
       white background, expanding the canvas so no content is clipped

  ## Contrast presets

    * `:none` — no change
    * `:auto` — min/max linear stretch to the full 0–255 range
    * `:high` — +35 % contrast about the 128 midpoint
    * `:low`  — −30 % contrast about the 128 midpoint
    * `:bw`   — hard threshold at the min/max midpoint (binarised)
  """

  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  @max_input_bytes 50 * 1024 * 1024
  @max_dimension 10_000
  @hough_max_side 640
  @hough_coarse_step 1.0
  @hough_refine_step 0.1
  @edge_threshold 8
  @max_edge_points 12_000

  @contrast_presets [:none, :auto, :high, :low, :bw]

  @type contrast_preset :: :none | :auto | :high | :low | :bw

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Converts image bytes into a single-page PDF.

  Options:

    * `:deskew` — `boolean()`, default `true`. Server-side skew correction.
    * `:contrast` — `Quire.Scan.contrast_preset()`, default `:auto`.

  Returns `{:ok, pdf_bytes}` or `{:error, reason}`.
  """
  @spec image_to_pdf(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def image_to_pdf(image_bytes, opts \\ []) when is_binary(image_bytes) do
    deskew? = Keyword.get(opts, :deskew, true)
    contrast = Keyword.get(opts, :contrast, :auto)

    with {:ok, img} <- load(image_bytes),
         {:ok, img} <- maybe_deskew(img, deskew?),
         {:ok, img} <- apply_contrast(img, contrast) do
      build_pdf(img)
    end
  end

  @doc """
  Detects the dominant edge angle of an image in degrees.

  `0.0` means the dominant edges are axis-aligned; a positive value means the
  content is tilted counter-clockwise in image coordinates (y-down). Accepts
  either raw image bytes or an already-loaded `Vix.Vips.Image`.

  Returns `{:ok, degrees}` or `{:error, reason}`.
  """
  @spec detect_angle(binary() | Image.t()) :: {:ok, float()} | {:error, term()}
  def detect_angle(image_bytes) when is_binary(image_bytes) do
    with {:ok, img} <- load(image_bytes) do
      detect_angle(img)
    end
  end

  def detect_angle(%Image{} = img) do
    with {:ok, gray} <- Operation.colourspace(img, :VIPS_INTERPRETATION_B_W),
         {:ok, small} <- downscale(gray),
         {:ok, edges} <- Operation.canny(small),
         {:ok, edges} <- Operation.cast(edges, :VIPS_FORMAT_UCHAR),
         points when points != [] <- edge_points(edges) do
      w = Image.width(small)
      h = Image.height(small)

      {theta_peak, _} = hough_peak(points, w, h, 45.0, 135.0, @hough_coarse_step)

      {theta_refined, _} =
        hough_peak(
          points,
          w,
          h,
          theta_peak - @hough_coarse_step,
          theta_peak + @hough_coarse_step,
          @hough_refine_step
        )

      # θ is the line *normal* angle; near-horizontal lines live at θ ≈ 90°.
      # line angle = 90 − θ, wrapped into [−45, 45].
      line_angle = wrap_line_angle(90.0 - theta_refined)
      {:ok, line_angle}
    else
      [] -> {:ok, 0.0}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deskews an image server-side via vix.

  Returns `{:ok, %Vix.Vips.Image{}, detected_degrees}` — the corrected image
  and the detected skew angle that was corrected for.
  """
  @spec deskew(Image.t()) :: {:ok, Image.t(), float()} | {:error, term()}
  def deskew(%Image{} = img) do
    with {:ok, angle} <- detect_angle(img) do
      with {:ok, rotated} <- rotate(img, -angle) do
        {:ok, rotated, angle}
      end
    end
  end

  @doc """
  Applies a contrast preset to an image. Returns `{:ok, %Vix.Vips.Image{}}`.
  """
  @spec apply_contrast(Image.t(), contrast_preset()) :: {:ok, Image.t()} | {:error, term()}
  def apply_contrast(%Image{} = img, :none), do: {:ok, img}

  def apply_contrast(%Image{} = img, :auto) do
    with {:ok, gray} <- Operation.colourspace(img, :VIPS_INTERPRETATION_B_W),
         {:ok, {mn, _}} <- Operation.min(gray),
         {:ok, {mx, _}} <- Operation.max(gray) do
      if mx > mn do
        a = 255.0 / (mx - mn)
        b = -a * mn
        linear_clipped(img, a, b)
      else
        {:ok, img}
      end
    end
  end

  def apply_contrast(%Image{} = img, :high), do: linear_clipped(img, 1.35, -44.8)

  def apply_contrast(%Image{} = img, :low), do: linear_clipped(img, 0.7, 38.4)

  def apply_contrast(%Image{} = img, :bw) do
    with {:ok, gray} <- Operation.colourspace(img, :VIPS_INTERPRETATION_B_W),
         {:ok, {mn, _}} <- Operation.min(gray),
         {:ok, {mx, _}} <- Operation.max(gray) do
      threshold = (mn + mx) / 2.0

      with {:ok, bin} <-
             Operation.relational_const(gray, :VIPS_OPERATION_RELATIONAL_MORE, [threshold]) do
        Operation.colourspace(bin, :VIPS_INTERPRETATION_sRGB)
      end
    end
  end

  def apply_contrast(%Image{}, other) do
    {:error, {:invalid_contrast, other, @contrast_presets}}
  end

  @doc """
  Returns the list of valid contrast preset atoms.
  """
  @spec contrast_presets() :: [contrast_preset()]
  def contrast_presets, do: @contrast_presets

  @doc """
  Builds a single-page PDF from a loaded image (sRGB, uchar).

  The image pixel maps 1:1 to PDF points (72 DPI) via an ExPdfium bitmap.
  """
  @spec build_pdf(Image.t()) :: {:ok, binary()} | {:error, term()}
  def build_pdf(%Image{} = img) do
    with {:ok, srgb} <- Operation.colourspace(img, :VIPS_INTERPRETATION_sRGB),
         {:ok, srgb} <- Operation.cast(srgb, :VIPS_FORMAT_UCHAR) do
      width = Image.width(srgb)
      height = Image.height(srgb)
      bitmap = to_pdfium_bitmap(srgb, width, height)

      with {:ok, doc} <- ExPdfium.new(),
           {:ok, doc} <- ExPdfium.add_page(doc, {width * 1.0, height * 1.0}),
           {:ok, doc} <-
             ExPdfium.draw_image(doc, 0, bitmap,
               at: %{left: 0.0, bottom: 0.0, right: width * 1.0, top: height * 1.0}
             ) do
        case ExPdfium.save_to_bytes(doc) do
          {:ok, pdf_bytes} ->
            ExPdfium.close(doc)
            {:ok, pdf_bytes}

          {:error, reason} ->
            ExPdfium.close(doc)
            {:error, reason}
        end
      end
    end
  end

  # ── Pipeline steps ─────────────────────────────────────────────────────

  defp load(image_bytes) do
    if byte_size(image_bytes) > @max_input_bytes do
      {:error, {:invalid_image, "Image exceeds the #{@max_input_bytes} byte limit"}}
    else
      load_image(image_bytes)
    end
  end

  defp load_image(image_bytes) do
    case Image.new_from_buffer(image_bytes) do
      {:ok, img} ->
        w = Image.width(img)
        h = Image.height(img)

        cond do
          w > @max_dimension or h > @max_dimension ->
            {:error, {:invalid_image, "Image dimensions #{w}x#{h} exceed #{@max_dimension} px"}}

          true ->
            img = if Image.has_alpha?(img), do: flatten!(img), else: img

            with {:ok, srgb} <- Operation.colourspace(img, :VIPS_INTERPRETATION_sRGB) do
              {:ok, srgb}
            end
        end

      {:error, _reason} ->
        {:error, {:invalid_image, "The file does not appear to be a supported image format"}}
    end
  end

  defp maybe_deskew(img, false), do: {:ok, img}

  defp maybe_deskew(img, true) do
    case deskew(img) do
      {:ok, corrected, _angle} -> {:ok, corrected}
      {:error, reason} -> {:error, reason}
    end
  end

  defp flatten!(img) do
    {:ok, flat} = Operation.flatten(img)
    flat
  end

  # ── Rotation ───────────────────────────────────────────────────────────

  defp rotate(img, angle) do
    w = Image.width(img)
    h = Image.height(img)

    Operation.similarity(img,
      angle: angle,
      odx: w / 2.0,
      ody: h / 2.0,
      background: [255, 255, 255]
    )
  end

  # ── Hough transform ────────────────────────────────────────────────────

  defp downscale(%Image{} = gray) do
    w = Image.width(gray)
    h = Image.height(gray)
    longest = max(w, h)

    if longest > @hough_max_side do
      scale = @hough_max_side / longest
      Operation.resize(gray, scale)
    else
      {:ok, gray}
    end
  end

  defp edge_points(%Image{} = edges) do
    w = Image.width(edges)
    {:ok, data} = Image.write_to_binary(edges)
    values = :binary.bin_to_list(data)

    # Canny magnitudes are uncalibrated — threshold relative to the peak so
    # the detector works on photos as well as synthetic fixtures.
    peak = Enum.max(values)
    threshold = max(peak * 0.5, @edge_threshold)

    points =
      values
      |> Enum.with_index()
      |> Enum.reduce([], fn {v, i}, acc ->
        if v >= threshold, do: [{rem(i, w), div(i, w)} | acc], else: acc
      end)

    case length(points) do
      0 ->
        []

      count when count <= @max_edge_points ->
        points

      count ->
        # Subsample evenly so the accumulator stays bounded on busy scans.
        step = count / @max_edge_points
        points |> Enum.reverse() |> subsample(step, 0.0, [])
    end
  end

  defp subsample([], _step, _pos, acc), do: acc

  defp subsample([p | rest], step, pos, acc) do
    if pos >= 1.0 do
      subsample(rest, step, pos - 1.0, [p | acc])
    else
      subsample(rest, step, pos + step, acc)
    end
  end

  defp hough_peak(points, w, h, theta_min, theta_max, step) do
    d = :math.sqrt(w * w + h * h)
    rho_bins = round(2 * d) + 1
    rho_offset = d

    count = round((theta_max - theta_min) / step)

    Enum.reduce(0..count, {-1.0, 0}, fn i, {best_theta, best_votes} ->
      theta = theta_min + i * step
      votes = count_votes(points, theta, rho_bins, rho_offset)

      if votes > best_votes, do: {theta, votes}, else: {best_theta, best_votes}
    end)
  end

  defp count_votes(points, theta, rho_bins, rho_offset) do
    rad = theta * :math.pi() / 180.0
    ct = :math.cos(rad)
    st = :math.sin(rad)

    {_, max_count} =
      Enum.reduce(points, {%{}, 0}, fn {x, y}, {acc, mx} ->
        idx = round(x * ct + y * st + rho_offset) |> min(rho_bins - 1) |> max(0)
        n = Map.get(acc, idx, 0) + 1
        {Map.put(acc, idx, n), max(mx, n)}
      end)

    max_count
  end

  defp wrap_line_angle(angle) when angle > 45.0, do: angle - 90.0
  defp wrap_line_angle(angle) when angle < -45.0, do: angle + 90.0
  defp wrap_line_angle(angle), do: angle

  # ── Contrast helpers ───────────────────────────────────────────────────

  defp linear_clipped(img, a, b) do
    bands = Image.bands(img)
    a_list = List.duplicate(a, bands)
    b_list = List.duplicate(b, bands)

    with {:ok, lin} <- Operation.linear(img, a_list, b_list) do
      Operation.cast(lin, :VIPS_FORMAT_UCHAR)
    end
  end

  # ── ExPdfium bitmap (Vix sRGB → BGR) ──────────────────────────────────

  defp to_pdfium_bitmap(srgb, width, height) do
    {:ok, raw_data} = Image.write_to_binary(srgb)

    %ExPdfium.Bitmap{
      data: swap_rb_3(raw_data),
      width: width,
      height: height,
      stride: width * 3,
      format: :bgr
    }
  end

  defp swap_rb_3(data) do
    for <<r::8, g::8, b::8 <- data>>, into: <<>>, do: <<b::8, g::8, r::8>>
  end
end
