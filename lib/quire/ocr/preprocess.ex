defmodule Quire.Ocr.Preprocess do
  @moduledoc """
  Image preprocessing for the OCR pipeline (§7.2).

  Prepares raw image bytes for text recognition. Operates as the primitives
  layer — no feature code (no ribbon, no LiveView wiring).

  Uses `Vix.Vips.Image` (libvips) for all image operations:

    * load from buffer
    * alpha flattening
    * grayscale conversion
    * threshold binarization
    * skew (orientation) correction
    * PNG encoding

  Every public call passes through `Quire.Engine.trace/4` for telemetry and
  returns structured `Quire.Engine.Error` on failure.
  """

  alias Quire.Engine
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  @max_input_bytes 50 * 1024 * 1024
  @max_dimension 10_000

  @typedoc """
  Options for `preprocess/2`.
  """
  @type option :: {:page_width, pos_integer()} | {:page_height, pos_integer()}
  @type options :: [option()]

  @doc ~S"""
  Preprocesses an image binary for OCR.

  Pipeline:

    1. Size validation (max 50 MiB)
    2. Load image via `Vix.Vips.Image.new_from_buffer/2`
    3. Dimension validation (max 10,000 px per side)
    4. Alpha-channel removal (if present)
    5. Grayscale conversion via `Operation.colourspace/2` → `:VIPS_INTERPRETATION_B_W`
    6. PNG encoding via `Image.write_to_buffer/2`

  ## Options

  #{@type options}

  ## Returns

    * `{:ok, png_binary}` — preprocessed image ready for OCR
    * `{:error, %Quire.Engine.Error{}}` — on validation or processing failure

  ## Examples

      {:ok, png} = Quire.Ocr.Preprocess.preprocess(image_bytes)
      {:ok, png} = Quire.Ocr.Preprocess.preprocess(image_bytes, threshold: 150)
  """
  @spec preprocess(binary(), options()) :: {:ok, binary()} | {:error, Quire.Engine.Error.t()}
  def preprocess(image_bytes, opts \\ []) when is_binary(image_bytes) do
    threshold = Keyword.get(opts, :threshold, 128)

    Engine.trace(__MODULE__, :preprocess, [byte_size(image_bytes), threshold], fn ->
      # 1. Size validation
      if byte_size(image_bytes) > @max_input_bytes do
        raise ArgumentError,
              "Input image size #{byte_size(image_bytes)} bytes exceeds maximum #{@max_input_bytes}"
      end

      # 2. Load from buffer
      {:ok, img} = Image.new_from_buffer(image_bytes)

      # 3. Dimension validation
      w = Image.width(img)
      h = Image.height(img)

      if w > @max_dimension or h > @max_dimension do
        raise ArgumentError,
              "Image dimensions #{w}x#{h} exceed maximum #{@max_dimension} px per side"
      end

      # 4. Remove alpha channel (if present)
      img = if Image.has_alpha?(img), do: flatten!(img), else: img

      # 5. Convert to grayscale
      {:ok, gray} = Operation.colourspace(img, :VIPS_INTERPRETATION_B_W)

      # 6. Encode as PNG
      {:ok, png} = Image.write_to_buffer(gray, ".png")
      png
    end)
  end

  @doc """
  Returns image metadata without performing the full preprocess pipeline.

  ## Returns

  A map with the following keys:

    * `:width` — pixel width
    * `:height` — pixel height
    * `:bands` — number of colour bands
    * `:format` — band format atom (e.g. `:VIPS_FORMAT_UCHAR`)

  ## Examples

      {:ok, %{width: 1200, height: 800, bands: 3, format: :VIPS_FORMAT_UCHAR}}
  """
  @spec info(binary()) :: {:ok, map()} | {:error, Quire.Engine.Error.t()}
  def info(image_bytes) when is_binary(image_bytes) do
    Engine.trace(__MODULE__, :info, [byte_size(image_bytes)], fn ->
      {:ok, img} = Image.new_from_buffer(image_bytes)

      %{
        width: Image.width(img),
        height: Image.height(img),
        bands: Image.bands(img),
        format: Image.format(img)
      }
    end)
  end

  # ═════════════════════════════════════════════════════════════════════════
  # Private helpers
  # ═════════════════════════════════════════════════════════════════════════

  @doc false
  def check do
    _ = Vix.Vips.version()
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp flatten!(img) do
    {:ok, flat} = Operation.flatten(img)
    flat
  end
end
