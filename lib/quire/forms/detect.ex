defmodule Quire.Forms.Detect do
  @moduledoc """
  Heuristic line/box detector for scanned forms (T-118 §9.4 / T-125 §9.8).

  Pure Elixir raster analysis over a PDFium-rendered page bitmap:

    1. threshold the bitmap into an ink mask
    2. find thin horizontal and vertical line segments
    3. close segments into boxes (form fields)
    4. standalone long horizontal lines become underline fields

  Output rects are in **PDF user space** (points, bottom-left origin), so
  they can be written straight into widget `/Rect` entries — the same
  convention the client's `viewport.convertToPdfPoint` produces for T-115
  signature placement.

  ## Limits

  Heuristic by nature: fields drawn with dashed/dotted lines or with no
  border at all are not detected.  The caller shows the detections as a
  preview and lets the user accept or discard before committing anything.

  ## Coordinate pipeline

  `ExPdfium.render_page/3` produces a display-oriented bitmap of the crop
  frame (page `/Rotate` applied).  Detection runs in that pixel space, then
  rects are mapped back through display-space points → unrotated content
  space (inverse `/Rotate`) → user space (crop-box origin added), mirroring
  `Quire.Geometry`'s rotation handling (§14.3).
  """

  alias Quire.Storage.Ref

  @type field :: %{kind: :text | :checkbox, page_index: non_neg_integer(), rect: [float()]}

  @default_dpi 150
  @default_threshold 150
  # px — checkbox sides are ~20 px at 150 dpi
  @min_line_len 18
  # px
  @min_box_w 20
  # px
  @min_box_h 14
  # px — square-ish boxes up to this size are checkboxes
  @checkbox_max 45
  # px — standalone horizontal lines become text fields
  @underline_min 60
  # px — default height above an underline field
  @field_band 30
  # px — corner continuity tolerance
  @corner_tol 3
  # px — max gap between scan lines of one segment
  @gap_tol 2
  # px — a "line" band must be at most this thick
  @line_thickness_max 12
  # a closed box must be mostly empty inside
  @ink_ratio_max 0.5
  # the band above an underline must be mostly empty
  @underline_ink_max 0.2

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Runs detection on every page of the document referenced by `ref`.

  Returns `{:ok, %{total: n, fields: [field]}}` where each field carries its
  `:page_index`, `:kind` (`:text` | `:checkbox`) and `:rect` in PDF user
  space points.
  """
  @spec detect_ref(Ref.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def detect_ref(ref, opts \\ []) do
    dpi = Keyword.get(opts, :dpi, @default_dpi)

    with {:ok, bytes} <- Quire.Storage.get(ref),
         {:ok, doc} <- ExPdfium.open_blob(bytes) do
      try do
        result = detect_doc(doc, dpi, opts)

        case result do
          {:ok, fields} -> {:ok, %{total: length(fields), fields: fields}}
          {:error, _} = err -> err
        end
      after
        ExPdfium.close(doc)
      end
    end
  end

  @doc """
  Reads AcroForm fields via the PDFium layer (§9.4), normalized to the same
  per-page detection shape `detect_ref/2` produces: `%{page_index, kind,
  name, rect}` where `rect` is `[x0, y0, x1, y1]` in PDF user-space points
  (y-up, crop-origin included).

  Unlike `detect_ref/2` this only surfaces fields a real `/AcroForm` already
  declares — digitised fillable PDFs.  Scanned paper forms have no AcroForm,
  so they return `{:ok, []}`.
  """
  @spec form_fields(Ref.t()) :: {:ok, [field]} | {:error, term()}
  def form_fields(ref) do
    case Quire.Render.form_fields(ref) do
      {:ok, fields} -> {:ok, Enum.map(fields, &normalise_acro_field/1)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Auto-detect the fields to offer "Fill automatically" over (§9.4).

  Priority: a real AcroForm (PDFium `form_fields`) wins — its rects are
  authoritative.  When the document has none (a scanned form), fall back to
  the heuristic line/box detector over the rendered pages.

  Returns `{:ok, %{total: n, fields: [field], source: :acroform | :scanned}}`.
  """
  @spec autodetect(Ref.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def autodetect(ref, opts \\ []) do
    case form_fields(ref) do
      {:ok, []} ->
        case detect_ref(ref, opts) do
          {:ok, %{total: total, fields: fields}} ->
            {:ok, %{total: total, fields: fields, source: :scanned}}

          {:error, _} = err ->
            err
        end

      {:ok, fields} ->
        {:ok, %{total: length(fields), fields: fields, source: :acroform}}

      {:error, _} = err ->
        err
    end
  end

  # PDFium exposes field bounds as a `%{left, bottom, right, top}` map; the
  # detector's shape is a flat `[x0, y0, x1, y1]` list in the same space.
  defp normalise_acro_field(%{bounds: nil}) do
    %{kind: :text, page_index: 0, name: nil, rect: [0, 0, 0, 0]}
  end

  defp normalise_acro_field(f) do
    %{left: l, bottom: b0, right: r, top: t} = f.bounds

    %{
      kind: acro_kind(f.type),
      page_index: f.page,
      name: f.name,
      rect: [to_f(l), to_f(b0), to_f(r), to_f(t)]
    }
  end

  defp acro_kind(:text), do: :text
  defp acro_kind(:checkbox), do: :checkbox
  defp acro_kind(:radio), do: :radio
  defp acro_kind(_), do: :text

  defp to_f(n) when is_integer(n), do: n * 1.0
  defp to_f(n) when is_float(n), do: n

  # ── Page loop ───────────────────────────────────────────────────────────

  defp detect_doc(doc, dpi, opts) do
    with {:ok, count} <- ExPdfium.page_count(doc) do
      Enum.reduce_while(0..(count - 1), {:ok, []}, fn page_index, {:ok, acc} ->
        case detect_page_of_doc(doc, page_index, dpi, opts) do
          {:ok, page_fields} -> {:cont, {:ok, acc ++ page_fields}}
          {:error, reason} -> {:halt, {:error, {:page_failed, page_index, reason}}}
        end
      end)
    end
  end

  defp detect_page_of_doc(doc, page_index, dpi, opts) do
    with {:ok, info} <- ExPdfium.page_info(doc, page_index),
         {:ok, bitmap} <- ExPdfium.render_page(doc, page_index, dpi: dpi) do
      {:ok, detect_page(bitmap, info, page_index, opts)}
    end
  end

  @doc """
  Detects fields on a single rendered page bitmap.

  `info` is the `ExPdfium.page_info/2` map (`:width`, `:height`,
  `:rotation`, `:boxes`).  `page_index` is attached to every field.
  Public so the pure algorithm can be tested directly against hand-built
  bitmaps.
  """
  @spec detect_page(ExPdfium.Bitmap.t(), map(), non_neg_integer(), keyword()) :: [field]
  def detect_page(bitmap, info, page_index, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    w = bitmap.width
    h = bitmap.height

    mask = build_mask(bitmap, threshold)

    hs = line_segments(mask, w, h, :horizontal, Keyword.get(opts, :min_line_len, @min_line_len))
    vs = line_segments(mask, w, h, :vertical, Keyword.get(opts, :min_line_len, @min_line_len))

    boxes = close_boxes(hs, vs, mask, w, h, opts)
    underlines = underline_fields(hs, boxes, mask, w, opts)

    (boxes ++ underlines)
    |> dedupe()
    |> Enum.map(&to_user_space(&1, w, h, info, opts))
    |> Enum.map(&Map.put(&1, :page_index, page_index))
  end

  # ── Ink mask ────────────────────────────────────────────────────────────

  # Row-major binary of 0/1 bytes, one byte per pixel, honouring the bitmap
  # stride (pdfium rows can be padded).  Luminance is the channel average so
  # coloured ink still registers as dark.
  defp build_mask(%ExPdfium.Bitmap{data: data, width: w, height: h, stride: stride}, threshold) do
    bands = div(stride, max(w, 1))
    bands = if bands in [1, 3, 4], do: bands, else: 3

    for y <- 0..(h - 1) do
      row = binary_part(data, y * stride, w * bands)
      mask_row(row, bands, threshold)
    end
    |> Enum.join()
  end

  defp mask_row(row, bands, threshold) do
    row
    |> channel_groups(bands)
    |> Enum.map(fn group ->
      lum = div(Enum.sum(group), bands)

      if lum < threshold, do: 1, else: 0
    end)
    |> :erlang.list_to_binary()
  end

  defp channel_groups(binary, bands) do
    for <<chunk::binary-size(^bands) <- binary>>, do: :binary.bin_to_list(chunk)
  end

  # ── Line segments ───────────────────────────────────────────────────────

  # Thin straight dark bands: merge overlapping runs across consecutive scan
  # lines, then keep segments that are line-like (longer than thick).
  defp line_segments(mask, w, h, orientation, min_len) do
    {primary, _secondary} =
      case orientation do
        :horizontal -> {h, w}
        :vertical -> {w, h}
      end

    segments =
      Enum.reduce(0..(primary - 1), %{}, fn i, active ->
        runs = runs_at(mask, w, h, orientation, i, min_len)
        advance_segments(active, runs, i, orientation)
      end)

    segments
    |> Map.values()
    |> Enum.map(&segment_metrics/1)
    |> Enum.filter(fn %{thickness: t, length: l} ->
      t <= @line_thickness_max and l >= min_len and l >= 4 * t
    end)
  end

  # Find dark runs on the given scan line.  `i` is the row (horizontal) or
  # column (vertical) index; returns [{start, length}] in the line's axis.
  defp runs_at(mask, w, h, orientation, i, min_len) do
    line =
      case orientation do
        :horizontal ->
          binary_part(mask, i * w, w)

        :vertical ->
          for y <- 0..(h - 1), into: <<>>, do: <<:binary.at(mask, y * w + i)>>
      end

    line
    |> scan_runs()
    |> Enum.filter(fn {_start, len} -> len >= min_len end)
  end

  # Scan a 0/1 byte binary for runs of 1s, returning [{start, length}].
  defp scan_runs(line) do
    do_scan_runs(line, 0, nil, [])
    |> Enum.reverse()
  end

  defp do_scan_runs(<<>>, idx, current, acc) do
    if current, do: [{elem(current, 0), idx - elem(current, 0)} | acc], else: acc
  end

  defp do_scan_runs(<<0, rest::binary>>, idx, current, acc) do
    acc = if current, do: [{elem(current, 0), idx - elem(current, 0)} | acc], else: acc
    do_scan_runs(rest, idx + 1, nil, acc)
  end

  defp do_scan_runs(<<1, rest::binary>>, idx, current, acc) do
    current = if current, do: current, else: {idx, 0}
    do_scan_runs(rest, idx + 1, current, acc)
  end

  # Fold runs into active segments: each run either extends a segment whose
  # span overlaps it (within tolerance) or starts a new one.
  defp advance_segments(active, runs, i, orientation) do
    Enum.reduce(runs, active, fn {start, len}, acc ->
      case find_overlap(acc, start, start + len, i) do
        nil ->
          Map.put(acc, {i, start}, new_segment(start, start + len, i, orientation))

        {key, _existing} ->
          Map.update!(acc, key, fn seg -> extend_segment(seg, start, start + len, i) end)
      end
    end)
  end

  # A run belongs to a segment only when the spans overlap AND the scan line
  # is adjacent to the segment's last line — otherwise two separated edges of
  # the same box would merge into one overly thick "line".
  defp find_overlap(segments, a0, a1, i) do
    Enum.find(segments, fn
      {_key, %{axis_start: s0, axis_end: s1, cross_end: c1}} ->
        a0 <= s1 + @corner_tol and a1 >= s0 - @corner_tol and i - c1 <= @gap_tol

      _ ->
        false
    end)
  end

  defp new_segment(a0, a1, i, orientation) do
    %{axis_start: a0, axis_end: a1, cross_start: i, cross_end: i, orientation: orientation}
  end

  defp extend_segment(%{axis_start: s0, axis_end: s1} = seg, a0, a1, i) do
    seg
    |> Map.put(:axis_start, min(s0, a0))
    |> Map.put(:axis_end, max(s1, a1))
    |> Map.put(:cross_end, i)
  end

  # Derive {length, thickness, centerlines} for a finished segment.
  defp segment_metrics(%{axis_start: a0, axis_end: a1, cross_start: c0, cross_end: c1} = seg) do
    seg
    |> Map.put(:length, a1 - a0)
    |> Map.put(:thickness, c1 - c0)
    |> Map.put(:axis_center, div(a0 + a1, 2))
    |> Map.put(:cross_center, div(c0 + c1, 2))
  end

  # ── Box closure ─────────────────────────────────────────────────────────

  # For each pair of horizontal segments (top, bottom), find vertical
  # segments spanning the pair and close the rectangle.  Ink-ratio and
  # nesting filters keep out filled blobs and duplicates.
  defp close_boxes(hs, vs, mask, w, _h, opts) do
    min_w = Keyword.get(opts, :min_box_w, @min_box_w)
    min_h = Keyword.get(opts, :min_box_h, @min_box_h)

    # Normalise to geometry terms: h-lines are {y, x0, x1}, v-lines are
    # {x, y0, y1} (a vertical scan runs along columns, so its axis is the
    # row range and its cross span is the column range).
    hs =
      Enum.map(hs, fn seg ->
        %{
          y: seg.cross_center,
          x0: seg.axis_start,
          x1: seg.axis_end,
          y_top: seg.cross_start,
          y_bot: seg.cross_end
        }
      end)

    vs =
      Enum.map(vs, fn seg ->
        %{
          x: seg.cross_center,
          y0: seg.axis_start,
          y1: seg.axis_end,
          x0: seg.cross_start,
          x1: seg.cross_end
        }
      end)

    pairs =
      for top <- hs,
          bottom <- hs,
          top.y < bottom.y,
          bottom.y - top.y >= min_h,
          overlap(top.x0, top.x1, bottom.x0, bottom.x1) >= min_w do
        {top, bottom}
      end

    Enum.reduce(pairs, [], fn {top, bottom}, acc ->
      shared_x0 = max(top.x0, bottom.x0)
      shared_x1 = min(top.x1, bottom.x1)

      lefts =
        Enum.filter(vs, fn v ->
          v.x >= shared_x0 - @corner_tol and
            v.x <= shared_x1 + @corner_tol and
            v.y0 <= top.y + @corner_tol and
            v.y1 >= bottom.y - @corner_tol
        end)

      boxed =
        for left <- lefts,
            right <- lefts,
            left.x < right.x,
            right.x - left.x >= min_w,
            top.x0 <= left.x + @corner_tol,
            top.x1 >= right.x - @corner_tol,
            bottom.x0 <= left.x + @corner_tol,
            bottom.x1 >= right.x - @corner_tol do
          %{
            kind: :box,
            x0: left.x,
            x1: right.x,
            y_top: top.y,
            y_bot: bottom.y,
            w: right.x - left.x,
            h: bottom.y - top.y
          }
        end

      Enum.reduce(boxed, acc, fn box, inner_acc ->
        if ink_ratio(mask, w, box.x0, box.y_top, box.x1, box.y_bot) < @ink_ratio_max do
          [box | inner_acc]
        else
          inner_acc
        end
      end)
    end)
  end

  defp overlap(a0, a1, b0, b1), do: min(a1, b1) - max(a0, b0)

  # Ink ratio (dark fraction) inside the pixel rect [x0..x1) × [y_top..y_bot).
  defp ink_ratio(mask, w, x0, y_top, x1, y_bot) do
    total = max((x1 - x0) * (y_bot - y_top), 1)

    dark =
      for y <- y_top..(y_bot - 1), reduce: 0 do
        acc ->
          row = binary_part(mask, y * w, w)
          acc + dark_in_row(row, x0, x1)
      end

    dark / total
  end

  defp dark_in_row(row, x0, x1) do
    for x <- x0..(x1 - 1), reduce: 0 do
      acc -> if :binary.at(row, x) == 1, do: acc + 1, else: acc
    end
  end

  # ── Underline fields ────────────────────────────────────────────────────

  # Long standalone horizontal lines (fill-in blanks) become text fields
  # with a default band of white space above the line.
  defp underline_fields(hs, boxes, mask, w, opts) do
    min_len = Keyword.get(opts, :underline_min, @underline_min)
    band = Keyword.get(opts, :field_band, @field_band)
    hs = Enum.map(hs, &segment_metrics/1)

    hs
    |> Enum.filter(fn seg ->
      seg.orientation == :horizontal and seg.length >= min_len and
        seg.axis_start > @corner_tol + 2 and seg.axis_end < w - @corner_tol - 2
    end)
    |> Enum.reject(fn seg ->
      Enum.any?(boxes, fn box ->
        seg.axis_center >= box.x0 and seg.axis_center <= box.x1 and
          seg.cross_center >= box.y_top and seg.cross_center <= box.y_bot
      end)
    end)
    |> Enum.map(fn seg ->
      y_top = max(seg.cross_start - band, 0)
      y_bot = seg.cross_end + 1

      %{
        kind: :box,
        x0: seg.axis_start,
        x1: seg.axis_end,
        y_top: y_top,
        y_bot: y_bot,
        w: seg.length,
        h: y_bot - y_top
      }
    end)
    |> Enum.filter(fn box ->
      ink_ratio(mask, w, box.x0, box.y_top, box.x1, max(box.y_bot - @corner_tol - 1, box.y_top)) <
        @underline_ink_max
    end)
  end

  # ── Classification + dedupe ─────────────────────────────────────────────

  defp classify(%{w: w_px, h: h_px}) do
    square = h_px <= @checkbox_max and w_px <= @checkbox_max
    ratio_ok = h_px > 0 and w_px / h_px >= 0.6 and w_px / h_px <= 1.8

    cond do
      square and ratio_ok and w_px >= @min_box_w and h_px >= @min_box_h -> :checkbox
      w_px >= @min_box_w and h_px >= @min_box_h -> :text
      true -> :text
    end
  end

  defp dedupe(boxes) do
    boxes
    |> Enum.sort_by(fn b -> b.w * b.h end, :desc)
    |> Enum.reduce([], fn box, acc ->
      contained = Enum.any?(acc, &contains?(&1, box))
      if contained, do: acc, else: [box | acc]
    end)
    |> Enum.reverse()
    |> Enum.reject(fn b ->
      b.w < @min_box_w or b.h < @min_box_h
    end)
  end

  defp contains?(outer, inner) do
    inner.x0 >= outer.x0 - @corner_tol and inner.x1 <= outer.x1 + @corner_tol and
      inner.y_top >= outer.y_top - @corner_tol and inner.y_bot <= outer.y_bot + @corner_tol
  end

  # ── Pixel → PDF user space ──────────────────────────────────────────────

  # Pixel rect (y grows down) → display-space points (y up) → unrotated
  # content space (inverse /Rotate) → user space (+ crop-box origin).
  defp to_user_space(%{x0: x0, x1: x1, y_top: yt, y_bot: yb} = box, _img_w, img_h, info, opts) do
    dpi = Keyword.get(opts, :dpi, @default_dpi)
    scale = 72.0 / dpi
    rotation = Integer.mod(info.rotation || 0, 360)

    {cw, ch, ox, oy} = content_frame(info)

    # 1. pixel → display-space points, y flipped to bottom-left origin
    dx0 = x0 * scale
    dx1 = x1 * scale
    dy0 = (img_h - yb) * scale
    dy1 = (img_h - yt) * scale

    # 2. display → unrotated content space (inverse rotation)
    {cx0, cy0, cx1, cy1} = display_rect_to_content(dx0, dy0, dx1, dy1, rotation, cw, ch)

    # 3. content frame → user space
    rect = [cx0 + ox, cy0 + oy, cx1 + ox, cy1 + oy]

    %{kind: classify(box), rect: rect}
  end

  # Unrotated content dims + origin from the page info boxes.
  defp content_frame(%{boxes: %{crop: %{left: l, bottom: b, right: r, top: t}}}),
    do: {r - l, t - b, l, b}

  defp content_frame(%{boxes: %{media: %{left: l, bottom: b, right: r, top: t}}}),
    do: {r - l, t - b, l, b}

  defp content_frame(%{width: w, height: h}), do: {w, h, 0.0, 0.0}

  # Inverse of Quire.Geometry.apply_rotation/5 (which maps content → display).
  # Display rect {dx0, dy0, dx1, dy1} in points, y-up; returns content rect.
  defp display_rect_to_content(dx0, dy0, dx1, dy1, 0, _cw, _ch), do: {dx0, dy0, dx1, dy1}

  defp display_rect_to_content(dx0, dy0, dx1, dy1, 90, cw, _ch) do
    {cw - dy1, dx0, cw - dy0, dx1}
  end

  defp display_rect_to_content(dx0, dy0, dx1, dy1, 180, cw, ch) do
    {cw - dx1, ch - dy1, cw - dx0, ch - dy0}
  end

  defp display_rect_to_content(dx0, dy0, dx1, dy1, 270, _cw, ch) do
    {dy0, ch - dx1, dy1, ch - dx0}
  end
end
