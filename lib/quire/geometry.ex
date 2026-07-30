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
end
