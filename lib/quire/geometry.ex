defmodule Quire.Geometry do
  @moduledoc """
  Geometry calculations for measurement tools (plan3.md §9.6, §14.3).

  All internal computations are in PDF points (1 pt = 1/72 inch) per
  ISO 32000-2 §14.3. Scale calibration converts point measurements to
  real-world units.
  """

  @doc """
  Euclidean distance between two `{x, y}` points.
  """
  def distance({x1, y1}, {x2, y2}) do
    :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
  end

  @doc """
  Perimeter of a closed polygon defined by a list of vertices.

  Vertices are `{x, y}` tuples. The polygon is closed automatically
  (last → first edge included). Returns 0.0 for fewer than 2 vertices.
  """
  def perimeter(vertices) when length(vertices) < 2, do: 0.0

  def perimeter(vertices) do
    edges = Enum.zip(vertices, tl(vertices) ++ [hd(vertices)])

    Enum.reduce(edges, 0.0, fn {a, b}, acc ->
      acc + distance(a, b)
    end)
  end

  @doc """
  Area of a polygon via the shoelace formula (Gauss's area formula).

  Vertices are `{x, y}` tuples. The polygon is closed automatically.
  Returns area in square PDF points. Returns 0.0 for < 3 vertices.
  """
  def area(vertices) when length(vertices) < 3, do: 0.0

  def area(vertices) do
    closed = vertices ++ [hd(vertices)]

    sum =
      closed
      |> Enum.zip(tl(closed))
      |> Enum.reduce(0.0, fn {{x1, y1}, {x2, y2}}, acc ->
        acc + (x1 * y2 - x2 * y1)
      end)

    abs(sum) / 2.0
  end

  @doc """
  Convert a measurement from one unit to another.

  Supported units: `:points`, `:inches`, `:mm`, `:cm`, `:meters`.
  """
  def scale_measurement(value, from_unit, to_unit)

  def scale_measurement(value, unit, unit), do: value

  def scale_measurement(value, from_unit, to_unit) do
    points = to_points(value, from_unit)
    from_points(points, to_unit)
  end

  # ── Conversion helpers ──────────────────────────────────────────────

  # PDF point: 1 pt = 1/72 inch
  @points_per_inch 72.0
  @mm_per_inch 25.4
  @cm_per_inch 2.54
  @meters_per_inch 0.0254

  defp to_points(value, :points), do: value
  defp to_points(value, :inches), do: value * @points_per_inch
  defp to_points(value, :mm), do: value * @points_per_inch / @mm_per_inch
  defp to_points(value, :cm), do: value * @points_per_inch / @cm_per_inch
  defp to_points(value, :meters), do: value * @points_per_inch / @meters_per_inch

  defp from_points(points, :points), do: points
  defp from_points(points, :inches), do: points / @points_per_inch
  defp from_points(points, :mm), do: points / @points_per_inch * @mm_per_inch
  defp from_points(points, :cm), do: points / @points_per_inch * @cm_per_inch
  defp from_points(points, :meters), do: points / @points_per_inch * @meters_per_inch

  @doc """
  Format a measurement value for display with the given unit atom.
  Rounds to a reasonable precision based on unit scale.
  """
  def format_measurement(value, unit) do
    decimals = measurement_decimals(unit)
    formatted = :erlang.float_to_binary(value, decimals: decimals)
    unit_label = unit_label(unit)
    "#{formatted} #{unit_label}"
  end

  defp measurement_decimals(:points), do: 1
  defp measurement_decimals(:inches), do: 2
  defp measurement_decimals(:mm), do: 1
  defp measurement_decimals(:cm), do: 2
  defp measurement_decimals(:meters), do: 3

  defp unit_label(:points), do: "pt"
  defp unit_label(:inches), do: "in"
  defp unit_label(:mm), do: "mm"
  defp unit_label(:cm), do: "cm"
  defp unit_label(:meters), do: "m"

  @doc """
  Convert CSS/canvas bounding rect (top-left origin) to PDF user-space
  points (bottom-left origin).

  Matches pdf.js `PageViewport.convertToPdfPoint`:

    rot 0:   x_pdf = x_css, y_pdf = pw - y_css - h
    rot 90:  x_pdf = pw  + y_css, y_pdf = -x_css - h
    rot 180: x_pdf = pw  - x_css, y_pdf = ph - y_css - h
    rot 270: x_pdf = y_css,       y_pdf = ph - x_css - h

  Where `pw` = PDF page width, `ph` = PDF page height.
  """
  def css_to_pdf(x, y, w, h, pw, ph, rotation \\ 0)

  def css_to_pdf(x, y, w, h, _pw, ph, 0) do
    {x, ph - y - h, w, h}
  end

  def css_to_pdf(x, y, w, h, pw, _ph, 90) do
    {pw + y, -x - h, w, h}
  end

  def css_to_pdf(x, y, w, h, pw, ph, 180) do
    {pw - x, ph - y - h, w, h}
  end

  def css_to_pdf(x, y, w, h, _pw, ph, 270) do
    {y, ph - x - h, w, h}
  end

  @doc """
  Convert PDF user-space rect (bottom-left origin) to CSS/canvas coords
  (top-left origin). Inverse of `css_to_pdf/7`.
  """
  def pdf_to_css(x, y, w, h, pw, ph, rotation \\ 0)

  def pdf_to_css(x, y, w, h, _pw, ph, 0) do
    {x, ph - y - h, w, h}
  end

  def pdf_to_css(x, y, w, h, pw, _ph, 90) do
    {-y - h, x - pw, w, h}
  end

  def pdf_to_css(x, y, w, h, pw, ph, 180) do
    {pw - x, ph - y - h, w, h}
  end

  def pdf_to_css(x, y, w, h, _pw, ph, 270) do
    {ph - y - h, x, w, h}
  end

  @doc """
  Apply page rotation to a point (x, y) on a page of dimensions (w, h).

  Returns `{rotated_x, rotated_y}` in the original coordinate system
  after applying the given rotation (degrees: 0, 90, 180, 270).
  """
  def apply_rotation(x, y, w, h, degrees) do
    case Integer.mod(degrees, 360) do
      0 -> {x, y}
      90 -> {y, w - x}
      180 -> {w - x, h - y}
      270 -> {h - y, x}
    end
  end

  @doc """
  Check that a CSS → PDF → CSS round trip is identity within 0.01 pt.

  Uses the same pdf.js-matched formulas as `css_to_pdf/7` and
  `pdf_to_css/7`.
  """
  def round_trip_ok?(x, y, w, h, pw, ph, rotation \\ 0) do
    {px, py, _pw, _ph} = css_to_pdf(x, y, w, h, pw, ph, rotation)
    {cx, cy, _cw, _ch} = pdf_to_css(px, py, w, h, pw, ph, rotation)

    abs(cx - x) <= 0.01 and abs(cy - y) <= 0.01
  end

  @doc """
  Subtract CropBox origin from a point.

  When CropBox has a non-zero origin, add it to get MediaBox-frame coords.
  """
  def subtract_crop_origin(x, y, crop_x, crop_y) do
    {x + crop_x, y + crop_y}
  end

  @doc """
  Add CropBox origin to a point (inverse of `subtract_crop_origin/4`).
  """
  def add_crop_origin(x, y, crop_x, crop_y) do
    {x - crop_x, y - crop_y}
  end

end
