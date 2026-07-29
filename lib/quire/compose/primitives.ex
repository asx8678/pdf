defmodule Quire.Compose.Primitives do
  @moduledoc """
  Content-stream and appearance-stream primitives (§7.2, §9.1).

  Pure Elixir module that generates PDF content-stream operators as iodata.
  These primitives form the building blocks that the `Quire.Compose` behaviour
  can orchestrate for full layout composition.

  Every function validates its inputs and returns `{:ok, iodata}` on success
  or `{:error, %Quire.Engine.Error{}}` on failure. Coordinate and dimension
  checks ensure no negative sizes or off-page positions are emitted; page
  dimensions default to A4 (595.28 × 841.89 pt) and are configurable via
  `:page_width` / `:page_height` in the opts.

  ## Appearance streams (§9.1)

  The `appearance_stream/3` function generates the content-stream operators for
  AcroForm field appearances. Callers wrap these operators in a Form XObject
  dictionary with the appropriate `/BBox`, `/Resources` and other entries before
  writing them to the document.
  """

  alias Quire.Engine

  @default_page_width 595.28
  @default_page_height 841.89
  @default_font "Helv"
  @default_font_size 12.0

  @doc """
  Generates a text-object fragment (BT … ET) with a single text-positioning
  operator and string.

  ## Options

    * `:font` — font name for the `/Tf` operator (default `"Helv"`)
    * `:font_size` — size in points (default `12.0`)
    * `:color` — any colour operator string, e.g. `"0 g"` or `"0 0 0 rg"`
      (omitted when not set)
    * `:leading` — leading for the `TL` operator (omitted when not set)
    * `:char_spacing` — character spacing for `Tc` (omitted when not set)
    * `:word_spacing` — word spacing for `Tw` (omitted when not set)
    * `:text_rise` — text rise for `Ts` (omitted when not set)
    * `:rendering_mode` — text rendering mode for `Tr` (0–7, omitted when
      not set)
    * `:page_width`, `:page_height` — bounds for the position check
      (default A4)

  ## Examples

      {:ok, iodata} = Quire.Compose.Primitives.text_object("Hello", 50, 750,
        font: "F1", font_size: 14, color: "0 0 0 rg")
  """
  @spec text_object(String.t(), number(), number(), keyword()) ::
          {:ok, IO.iodata()} | {:error, Engine.Error.t()}
  def text_object(text, x, y, opts \\ []) do
    page_w = Keyword.get(opts, :page_width, @default_page_width)
    page_h = Keyword.get(opts, :page_height, @default_page_height)

    with :ok <- validate_position(x, y, page_w, page_h),
         :ok <- validate_string(text) do
      font = Keyword.get(opts, :font, @default_font)
      font_size = Keyword.get(opts, :font_size, @default_font_size)
      escaped = escape_pdf_string(text)

      ops = [
        "BT\n",
        "/#{font} #{format_number(font_size)} Tf\n",
        optional_color(Keyword.get(opts, :color)),
        optional_number("TL", Keyword.get(opts, :leading)),
        optional_number("Tc", Keyword.get(opts, :char_spacing)),
        optional_number("Tw", Keyword.get(opts, :word_spacing)),
        optional_number("Ts", Keyword.get(opts, :text_rise)),
        optional_number("Tr", Keyword.get(opts, :rendering_mode)),
        "1 0 0 1 #{format_number(x)} #{format_number(y)} Tm\n",
        "(#{escaped}) Tj\n",
        "ET\n"
      ]

      {:ok, ops}
    end
  end

  @doc """
  Generates an image-placement fragment: `cm` (scale + translate) plus `Do`.

  ## Options

    * `:page_width`, `:page_height` — bounds for the position check
      (default A4)

  ## Examples

      {:ok, iodata} = Quire.Compose.Primitives.image_placement("Im0", 0, 0, 200, 150)
  """
  @spec image_placement(String.t(), number(), number(), number(), number(), keyword()) ::
          {:ok, IO.iodata()} | {:error, Engine.Error.t()}
  def image_placement(ref_name, x, y, w, h, opts \\ []) do
    page_w = Keyword.get(opts, :page_width, @default_page_width)
    page_h = Keyword.get(opts, :page_height, @default_page_height)

    with :ok <- validate_position(x, y, page_w, page_h),
         :ok <- validate_dimensions(w, h) do
      ops = [
        "#{format_number(w)} 0 0 #{format_number(h)} #{format_number(x)} #{format_number(y)} cm\n",
        "/#{ref_name} Do\n"
      ]

      {:ok, ops}
    end
  end

  @doc """
  Generates a rectangle path fragment (`re`) with optional fill / stroke.

  ## Options

    * `:fill` — apply the `f` (fill) operator
    * `:stroke` — apply the `S` (stroke) operator
    * `:fill_stroke` — apply the `B` (fill + stroke) operator; takes
      precedence over `:fill` and `:stroke` when set
    * `:close` — close path before painting (uses `b` / `s` / `n` instead
      of `B` / `S` / `f` when combined with fill / stroke)
    * `:page_width`, `:page_height` — bounds for the position check
      (default A4)

  When none of `:fill`, `:stroke` or `:fill_stroke` is true the path is
  defined but not painted (the `n` (no-op) operator is used), which is
  useful for clipping or when a caller wants to defer the painting operator.
  """
  @spec rectangle(number(), number(), number(), number(), keyword()) ::
          {:ok, IO.iodata()} | {:error, Engine.Error.t()}
  def rectangle(x, y, w, h, opts \\ []) do
    page_w = Keyword.get(opts, :page_width, @default_page_width)
    page_h = Keyword.get(opts, :page_height, @default_page_height)

    with :ok <- validate_position(x, y, page_w, page_h),
         :ok <- validate_dimensions(w, h) do
      op = painting_operator(opts)

      {:ok,
       [
         "#{format_number(x)} #{format_number(y)} #{format_number(w)} #{format_number(h)} re\n",
         op
       ]}
    end
  end

  @doc """
  Generates a line path fragment (`m` + `l`) with optional stroking.

  ## Options

    * `:stroke` — apply the `S` operator (default `true`)
    * `:page_width`, `:page_height` — bounds for the endpoint check
      (default A4)

  Both endpoints are checked against page bounds.
  """
  @spec line(number(), number(), number(), number(), keyword()) ::
          {:ok, IO.iodata()} | {:error, Engine.Error.t()}
  def line(x1, y1, x2, y2, opts \\ []) do
    page_w = Keyword.get(opts, :page_width, @default_page_width)
    page_h = Keyword.get(opts, :page_height, @default_page_height)

    with :ok <- validate_position(x1, y1, page_w, page_h),
         :ok <- validate_position(x2, y2, page_w, page_h) do
      stroke? = Keyword.get(opts, :stroke, true)

      path_op =
        if stroke? do
          "S\n"
        else
          "n\n"
        end

      {:ok,
       [
         "#{format_number(x1)} #{format_number(y1)} m\n",
         "#{format_number(x2)} #{format_number(y2)} l\n",
         path_op
       ]}
    end
  end

  @doc """
  Generates the content-stream operators for an AcroForm appearance stream.

  Returns the content-stream bytes *only* — callers wrap these in a Form
  XObject dictionary with `/BBox`, `/Resources` and other required entries.

  Telemetry events (`[:quire, :engine, :start | :stop | :exception]`) are
  emitted through `Quire.Engine.trace/4`.

  ## Field types

    * `:checkbox` — draws a checked mark (✓) or an empty box depending on
      `value`
    * `:radio` — draws a filled or empty circle depending on `value`
    * `:text` — renders the `value` string inside a rectangle using
      `/DA`-style font and colour settings

  ## Options

    * `:w`, `:h` — dimensions of the appearance rectangle (required)
    * `:background_color` — fill colour for the widget background
      (e.g. `"0.93 0.93 0.93 rg"`; omitted when not set)
    * `:border_color` — stroke colour for the border (default `"0 g"`)
    * `:border_width` — line width for the border (default `1.0`)
    * `:font` — font name (default `"Helv"`; text fields only)
    * `:font_size` — font size (default `12.0`; text fields only)
    * `:color` — text colour operator (default `"0 g"`; text fields only)
    * `:da` — full default-appearance string; when provided `:font`,
      `:font_size` and `:color` are ignored and the value is parsed with
      `parse_da/1` (text fields only)
    * `:page_width`, `:page_height` — bounds for the position check at
      origin (default A4)

  ## Examples

      {:ok, stream} = Quire.Compose.Primitives.appearance_stream(:checkbox, true,
        w: 12, h: 12)
  """
  @spec appearance_stream(atom(), term(), keyword()) ::
          {:ok, IO.iodata()} | {:error, Engine.Error.t()}
  def appearance_stream(field_type, value, opts \\ []) do
    with :ok <- validate_appearance_opts(field_type, value, opts) do
      Engine.trace(__MODULE__, :appearance_stream, [field_type, value, opts], fn ->
        page_w = Keyword.get(opts, :page_width, @default_page_width)
        page_h = Keyword.get(opts, :page_height, @default_page_height)
        w = Keyword.fetch!(opts, :w)
        h = Keyword.fetch!(opts, :h)

        validate_pos!(0, 0, page_w, page_h)
        validate_dims!(w, h)
        draw_appearance(field_type, value, opts)
      end)
    end
  end

  @doc """
  Joins multiple primitive results into a single content-stream iodata.

  Accepts a list of `{:ok, iodata}` tuples (as returned by the functions
  in this module) or raw iodata fragments. Returns `{:error, %Engine.Error{}}`
  on the first failing element.

  ## Examples

      {:ok, stream} = Quire.Compose.Primitives.compose([
        Quire.Compose.Primitives.text_object("Hello", 50, 750),
        Quire.Compose.Primitives.rectangle(50, 700, 100, 50, fill: true)
      ])
  """
  @spec compose([{:ok, IO.iodata()} | IO.iodata()]) ::
          {:ok, IO.iodata()} | {:error, Engine.Error.t()}
  def compose(ops) when is_list(ops) do
    result =
      Enum.reduce_while(ops, [], fn
        {:ok, iodata}, acc ->
          {:cont, [acc, iodata]}

        {:error, _} = err, _acc ->
          {:halt, err}

        iodata, acc when is_binary(iodata) or is_list(iodata) ->
          {:cont, [acc, iodata]}

        bad, _acc ->
          {:halt,
           {:error,
            %Engine.Error{
              engine: __MODULE__,
              operation: :compose,
              code: :invalid_argument,
              message: "expected {:ok, iodata} or iodata, got: #{inspect(bad)}"
            }}}
      end)

    case result do
      {:error, _} = err -> err
      parts -> {:ok, parts}
    end
  end

  # ── Helpers (documented for use by AcroForm and other callers) ─────────────

  @doc false
  def parse_da(da) when is_binary(da) do
    tokens = String.split(da)

    case find_tf(tokens) do
      {font_idx, size_idx} ->
        font_name = tokens |> Enum.at(font_idx) |> String.trim_leading("/")

        size =
          case Float.parse(Enum.at(tokens, size_idx) || "12") do
            {f, _} -> f
            :error -> 12.0
          end

        color_tokens = tokens |> Enum.drop(size_idx + 2)

        {font_name, size, da_color_part(color_tokens)}

      nil ->
        {"Helv", 12.0, "0 g"}
    end
  end

  defp da_color_part([a, op | _]) when op in ["g", "G"], do: "#{a} #{op}"
  defp da_color_part([a, b, c, op | _]) when op in ["rg", "RG"], do: "#{a} #{b} #{c} #{op}"
  defp da_color_part([a, b, c, d, op | _]) when op in ["k", "K"], do: "#{a} #{b} #{c} #{d} #{op}"
  defp da_color_part(_), do: "0 g"

  @doc false
  def escape_pdf_string(s) when is_binary(s) do
    s
    |> :binary.replace("\\", "\\\\", [:global])
    |> :binary.replace("(", "\\(", [:global])
    |> :binary.replace(")", "\\)", [:global])
    |> :binary.replace("\n", "\\n", [:global])
    |> :binary.replace("\r", "\\r", [:global])
    |> :binary.replace("\t", "\\t", [:global])
  end

  # ── Validation ─────────────────────────────────────────────────────────────

  defp validate_position(x, y, page_w, page_h) when is_number(x) and is_number(y) do
    cond do
      x < 0 or y < 0 ->
        {:error,
         %Engine.Error{
           engine: __MODULE__,
           operation: :validate_position,
           code: :invalid_argument,
           message: "coordinate out of bounds: (#{x}, #{y}) < (0, 0)"
         }}

      x > page_w or y > page_h ->
        {:error,
         %Engine.Error{
           engine: __MODULE__,
           operation: :validate_position,
           code: :invalid_argument,
           message: "coordinate out of bounds: (#{x}, #{y}) > (#{page_w}, #{page_h})"
         }}

      true ->
        :ok
    end
  end

  defp validate_position(_x, _y, _page_w, _page_h) do
    {:error,
     %Engine.Error{
       engine: __MODULE__,
       operation: :validate_position,
       code: :invalid_argument,
       message: "coordinates must be numbers"
     }}
  end

  defp validate_dimensions(w, h) when is_number(w) and is_number(h) do
    if w > 0 and h > 0 do
      :ok
    else
      {:error,
       %Engine.Error{
         engine: __MODULE__,
         operation: :validate_dimensions,
         code: :invalid_argument,
         message: "dimensions must be positive, got: #{w} x #{h}"
       }}
    end
  end

  defp validate_dimensions(_w, _h) do
    {:error,
     %Engine.Error{
       engine: __MODULE__,
       operation: :validate_dimensions,
       code: :invalid_argument,
       message: "dimensions must be numbers"
     }}
  end

  defp validate_string(s) when is_binary(s), do: :ok

  defp validate_string(_s) do
    {:error,
     %Engine.Error{
       engine: __MODULE__,
       operation: :validate_string,
       code: :invalid_argument,
       message: "text must be a string"
     }}
  end

  defp validate_pos!(x, y, pw, ph) do
    unless is_number(x) and is_number(y) and x >= 0 and y >= 0 and x <= pw and y <= ph do
      raise ArgumentError, "coordinate out of bounds: (#{x}, #{y})"
    end
  end

  defp validate_dims!(w, h) do
    unless is_number(w) and is_number(h) and w > 0 and h > 0 do
      raise ArgumentError, "dimensions must be positive, got: #{w} x #{h}"
    end
  end

  defp validate_appearance_opts(field_type, _value, opts)
       when field_type in [:checkbox, :radio, :text] do
    w = Keyword.get(opts, :w)
    h = Keyword.get(opts, :h)

    cond do
      not is_number(w) or not is_number(h) ->
        {:error,
         %Engine.Error{
           engine: __MODULE__,
           operation: :appearance_stream,
           code: :invalid_argument,
           message: "appearance dimensions :w and :h are required and must be numbers"
         }}

      w <= 0 or h <= 0 ->
        {:error,
         %Engine.Error{
           engine: __MODULE__,
           operation: :appearance_stream,
           code: :invalid_argument,
           message: "appearance dimensions must be positive, got: #{w} x #{h}"
         }}

      true ->
        :ok
    end
  end

  defp validate_appearance_opts(bad, _value, _opts) do
    {:error,
     %Engine.Error{
       engine: __MODULE__,
       operation: :appearance_stream,
       code: :invalid_argument,
       message: "unknown appearance field type: #{inspect(bad)}"
     }}
  end

  # ── Appearance generation ──────────────────────────────────────────────────

  defp draw_appearance(:checkbox, value, opts) do
    w = Keyword.fetch!(opts, :w)
    h = Keyword.fetch!(opts, :h)
    bg = Keyword.get(opts, :background_color)
    border_color = Keyword.get(opts, :border_color, "0 g")
    border_width = Keyword.get(opts, :border_width, 1.0)

    # Start with graphics state save so fill/stroke/colour changes are local
    ops = [
      "q\n",
      optional_color(bg),
      "0 0 #{format_number(w)} #{format_number(h)} re\n",
      "f\n",
      "#{format_number(border_width)} w\n",
      "#{border_color}\n",
      "0 0 #{format_number(w)} #{format_number(h)} re\n",
      "S\n"
    ]

    ops =
      if value do
        # Draw a check mark: two crossing lines from the corners of an
        # inset region
        margin = w * 0.2
        line_w = w * 0.12
        lx = margin
        ly = margin
        rx = w - margin
        ry = h - margin

        [
          ops,
          "#{format_number(line_w)} w\n",
          "#{border_color}\n",
          "1 0 0 1 0 0 cm\n",
          "#{format_number(lx)} #{format_number(ly)} m\n",
          "#{format_number(rx)} #{format_number(ry)} l\n",
          "S\n",
          "#{format_number(lx)} #{format_number(ry)} m\n",
          "#{format_number(rx)} #{format_number(ly)} l\n",
          "S\n"
        ]
      else
        ops
      end

    [ops, "Q\n"]
  end

  defp draw_appearance(:radio, value, opts) do
    w = Keyword.fetch!(opts, :w)
    h = Keyword.fetch!(opts, :h)
    bg = Keyword.get(opts, :background_color)
    border_color = Keyword.get(opts, :border_color, "0 g")
    border_width = Keyword.get(opts, :border_width, 1.0)

    cx = w / 2.0
    cy = h / 2.0
    outer_r = min(w, h) / 2.0 - border_width / 2.0

    ops = [
      "q\n",
      optional_color(bg)
    ]

    # Draw outer circle (border)
    ops = [
      ops,
      "#{format_number(border_width)} w\n",
      "#{border_color}\n",
      circle_path(cx, cy, outer_r),
      "S\n"
    ]

    ops =
      if value do
        # Filled inner circle
        inner_r = outer_r * 0.5
        [ops, "#{border_color}\n", circle_path(cx, cy, inner_r), "f\n"]
      else
        ops
      end

    [ops, "Q\n"]
  end

  defp draw_appearance(:text, value, opts) when is_binary(value) do
    w = Keyword.fetch!(opts, :w)
    h = Keyword.fetch!(opts, :h)
    bg = Keyword.get(opts, :background_color)
    border_color = Keyword.get(opts, :border_color, "0 g")
    border_width = Keyword.get(opts, :border_width, 1.0)

    {font, font_size, color} = resolve_text_appearance_font(opts)
    escaped = escape_pdf_string(truncate_to_fit(value, w, font_size))
    margin = 2.0

    ops = [
      "q\n",
      optional_color(bg),
      "#{format_number(border_width)} w\n",
      "#{border_color}\n",
      "0 0 #{format_number(w)} #{format_number(h)} re\n",
      "B\n",
      "#{color}\n",
      "BT\n",
      "/#{font} #{format_number(font_size)} Tf\n",
      "1 0 0 1 #{format_number(margin)} #{format_number(margin)} Tm\n",
      "(#{escaped}) Tj\n",
      "ET\n",
      "Q\n"
    ]

    ops
  end

  defp draw_appearance(:text, _value, opts) do
    # Non-string / nil value — draw an empty appearance
    draw_appearance(:text, "", opts)
  end

  defp resolve_text_appearance_font(opts) do
    case Keyword.get(opts, :da) do
      nil ->
        {
          Keyword.get(opts, :font, @default_font),
          Keyword.get(opts, :font_size, @default_font_size),
          Keyword.get(opts, :color, "0 g")
        }

      da_string ->
        {font, size, color} = parse_da(da_string)
        {font, size, color}
    end
  end

  # ── Path helpers ───────────────────────────────────────────────────────────

  defp circle_path(cx, cy, r) do
    # Approximate a circle with four cubic bezier curves.
    # Uses the standard kappa = 4*(sqrt(2)-1)/3 ≈ 0.55228
    k = r * 0.55228

    [
      "#{format_number(cx)} #{format_number(cy + r)} m\n",
      "#{format_number(cx + k)} #{format_number(cy + r)} #{format_number(cx + r)} #{format_number(cy + k)} #{format_number(cx + r)} #{format_number(cy)} c\n",
      "#{format_number(cx + r)} #{format_number(cy - k)} #{format_number(cx + k)} #{format_number(cy - r)} #{format_number(cx)} #{format_number(cy - r)} c\n",
      "#{format_number(cx - k)} #{format_number(cy - r)} #{format_number(cx - r)} #{format_number(cy - k)} #{format_number(cx - r)} #{format_number(cy)} c\n",
      "#{format_number(cx - r)} #{format_number(cy + k)} #{format_number(cx - k)} #{format_number(cy + r)} #{format_number(cx)} #{format_number(cy + r)} c\n",
      "h\n"
    ]
  end

  # ── Operator helpers ────────────────────────────────────────────────────────

  defp painting_operator(opts) do
    close? = Keyword.get(opts, :close, false)

    cond do
      Keyword.get(opts, :fill_stroke) ->
        if close?, do: "b\n", else: "B\n"

      Keyword.get(opts, :fill) ->
        if close?, do: "b\n", else: "f\n"

      Keyword.get(opts, :stroke) ->
        if close?, do: "s\n", else: "S\n"

      true ->
        "n\n"
    end
  end

  defp optional_color(nil), do: []
  defp optional_color(color), do: ["#{color}\n"]

  defp optional_number(_op, nil), do: []
  defp optional_number(op, val) when is_number(val), do: ["#{format_number(val)} #{op}\n"]

  # ── Formatting ─────────────────────────────────────────────────────────────

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)

  defp format_number(n) when is_float(n) do
    s = :erlang.float_to_binary(n, [:compact, decimals: 4])
    if String.contains?(s, "."), do: s, else: s <> ".0"
  end

  # ── /DA parsing (shared with AcroForm) ─────────────────────────────────────

  defp find_tf(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.find_value(fn
      {token, idx} -> if token == "Tf" and idx >= 2, do: {idx - 2, idx - 1}
      _ -> nil
    end)
  end

  # ── Simple truncation for text fields ──────────────────────────────────────

  @doc false
  def check do
    :ok
  end

  defp truncate_to_fit(text, _width, _font_size) do
    # A proper implementation would measure text extents, but at the primitive
    # level this is delegated to the caller for accurate metrics.
    # As a safety net, limit to 256 characters to avoid pathological input in
    # an appearance stream.
    if byte_size(text) > 256, do: binary_part(text, 0, 256), else: text
  end
end
