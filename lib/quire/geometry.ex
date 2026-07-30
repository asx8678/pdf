defmodule Quire.Geometry do
  @moduledoc """
  PDF ↔ CSS coordinate conversions (§14.3).

  All spatial values stored in **PDF points** (1/72 inch).
  Convert at the boundary — never do the maths inline.

  ## The four rules

  1. **Origin.** PDF is bottom-left, Y up. CSS is top-left, Y down.
     `y_pdf = page_height - y_css - h`
  2. **Units.** PDF user space = points. Store in points, convert at boundary.
  3. **Rotation.** /Rotate rotates the display, not the coordinate space.
     On the client, pdf.js's PageViewport handles this. Server-side,
     we use the standard rotation matrix.
  4. **CropBox ≠ MediaBox.** Subtract non-zero CropBox origin.
  """

  @doc """
  Convert CSS coordinates to PDF user-space points (no rotation handling).
  """
  def css_to_pdf(x_css, y_css, w, h, page_height) do
    %{
      x: x_css,
      y: page_height - y_css - h,
      width: w,
      height: h
    }
  end

  @doc """
  Convert PDF points to CSS coordinates (no rotation handling).
  """
  def pdf_to_css(x_pdf, y_pdf, w_pdf, h_pdf, page_height) do
    %{
      x: x_pdf,
      y: page_height - y_pdf - h_pdf,
      width: w_pdf,
      height: h_pdf
    }
  end

  @doc """
  Apply /Rotate to a point (server-side, since pdf.js viewport isn't available).
  Returns transformed `{x, y}`.

  Rotation is counter-clockwise around the page origin (bottom-left).
  """
  def apply_rotation(x, y, width, height, rotation) do
    case Integer.mod(rotation, 360) do
      0 -> {x, y}
      90 -> {y, width - x}
      180 -> {width - x, height - y}
      270 -> {height - y, x}
    end
  end

  @doc """
  Subtract CropBox origin to get MediaBox-frame coordinates.
  """
  def subtract_crop_origin(x, y, crop_origin_x, crop_origin_y) do
    {x + crop_origin_x, y + crop_origin_y}
  end

  @doc """
  Add CropBox origin (inverse).
  """
  def add_crop_origin(x, y, crop_origin_x, crop_origin_y) do
    {x - crop_origin_x, y - crop_origin_y}
  end

  @doc """
  Round-trip: CSS → PDF → CSS within tolerance.
  Returns true if the round-trip is the identity within `tolerance`.
  """
  def round_trip_ok?(x_css, y_css, w, h, page_height, tolerance \\ 0.01) do
    pdf = css_to_pdf(x_css, y_css, w, h, page_height)
    css_back = pdf_to_css(pdf.x, pdf.y, pdf.width, pdf.height, page_height)

    abs(css_back.x - x_css) <= tolerance &&
      abs(css_back.y - y_css) <= tolerance &&
      abs(css_back.width - w) <= tolerance &&
      abs(css_back.height - h) <= tolerance
  end
end
