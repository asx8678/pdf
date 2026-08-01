defmodule Quire.Editing.Mark.Placement do
  @moduledoc """
  Placement geometry for page marks (plan3.md §14.3, T-095).

  Computes where a stamp lands on a page, in **PDF user space**, from the
  display-oriented geometry that `Quire.Render.page_geometry/1` reports
  (CropBox-based width/height plus `/Rotate`).

  The model, verified against PDFium renders:

    * Anchors and margins are expressed in the **display frame** — the
      same frame the user sees and that `page_geometry/1` returns:
      width × height with `/Rotate` already applied, bottom-left origin.
    * A display point maps to **content space** (the page's user space,
      where `ExPdfium.draw_text/6` draws) by rotating back: for `/Rotate`
      `r`, `apply_rotation(x, y, display_w, display_h, 360 - r)`.
    * A non-zero `/CropBox` origin shifts the content frame, so the
      crop origin is added after the rotation. This reproduces the
      renderer for every rotation — verified with a synthetic
      `/Rotate 90` + `/CropBox [72 72 540 720]` page.

  The returned rect is `[x0, y0, x1, y1]` in user space. All units are
  PDF points (1/72 in), per §14.3 rule 2.

  ## Geometry input

  `geometry` is one `page_geometry/1` entry: `%{width:, height:, rotate:}`.
  `rotate` is the clockwise `/Rotate` in degrees (0, 90, 180, 270).
  """

  alias Quire.Geometry

  @doc """
  Returns the placement rect for one anchor on one page.

  ## Parameters

    * `anchor` — one of `Quire.Editing.Mark.anchors/0`
    * `margin` — distance from the page edge in points (default 36.0)
    * `geometry` — `%{width:, height:, rotate:}` display geometry
    * `opts` — `:crop_origin` as `{x, y}` (default `{0, 0}`)

  Returns `[x0, y0, x1, y1]` in user space. The rect is the text cell:
  `y0` is the baseline, `y1 = y0 + font_size`, and `x0..x1` spans the
  glyph width — `Mark.origin/2` uses `{x0, y1}` as the drawing origin so
  the PDFium text object's baseline sits at `y0`.
  """
  @spec rect(String.t(), number(), map(), keyword()) :: [number()]
  def rect(anchor, margin, geometry, opts \\ []) do
    page_w = geometry[:width] * 1.0
    page_h = geometry[:height] * 1.0
    rotate = Integer.mod(geometry[:rotate] || 0, 360)
    font_size = Keyword.get(opts, :font_size, 12.0)
    m = margin * 1.0
    crop = Keyword.get(opts, :crop_origin, {0, 0})

    # Approximate the glyph width from a standard-14 font's average glyph
    # advance (Helvetica's /Widths average ≈ 0.5 em) plus the font size —
    # the caller can override with :approx_width for exact metrics.
    approx_w = Keyword.get(opts, :approx_width, font_size * 0.55)

    {ax, ay, aw} = display_anchor(anchor, page_w, page_h, m, approx_w, font_size)

    # Display frame → content space: rotate back, then add the crop origin.
    {cx, cy} = Geometry.apply_rotation(ax, ay, page_w, page_h, 360 - rotate)
    {crop_x, crop_y} = crop
    {cx, cy} = {cx + crop_x, cy + crop_y}

    # The drawn text advances in content space; width is unaffected by the
    # axis swap of /Rotate 90/270 when the anchor is axis-aligned, so the
    # content-space width equals the display width.
    [cx, cy, cx + aw, cy + font_size]
  end

  @doc """
  Returns `{x, y, width}` of the anchor's text cell in the display frame.

  `width` is the caller-provided text width (used for left/centre/right
  placement). `y` is the baseline of the text cell (bottom for bottom
  anchors, `page_h - margin - font_size` for top anchors).
  """
  @spec display_anchor(String.t(), number(), number(), number(), number(), number()) ::
          {number(), number(), number()}
  def display_anchor(anchor, page_w, page_h, margin, text_w, font_size) do
    case anchor do
      "bottom_left" -> {margin, margin, text_w}
      "bottom_center" -> {(page_w - text_w) / 2, margin, text_w}
      "bottom_right" -> {page_w - margin - text_w, margin, text_w}
      "top_left" -> {margin, page_h - margin - font_size, text_w}
      "top_center" -> {(page_w - text_w) / 2, page_h - margin - font_size, text_w}
      "top_right" -> {page_w - margin - text_w, page_h - margin - font_size, text_w}
    end
  end

  @doc """
  Returns the `{x, y}` CropBox origin for a `page_geometry/1` entry, if
  the caller supplied the raw page boxes.

  Accepts either the geometry map (`:crop_origin` key) or a map with
  `:crop` / `:media` boxes (as returned by
  `ExPdfium.page_info/2`-style introspection). Returns `{0, 0}` when no
  crop box is present.
  """
  @spec crop_origin(map()) :: {number(), number()}
  def crop_origin(%{crop_origin: {x, y}}), do: {x, y}

  def crop_origin(%{crop: %{left: l, bottom: b}}), do: {l, b}
  def crop_origin(%{crop: nil}), do: {0, 0}
  def crop_origin(_), do: {0, 0}
end
