defmodule Quire.Ocr.Tesseract do
  @moduledoc """
  OCR engine wrapping `Image.OCR` for Tesseract/Leptonica-based image-to-text
  extraction (§7.2).

  Delegates to `Image.OCR` which links against Homebrew's Tesseract and
  Leptonica at runtime.

  ## Conventions

    * A 50 MB size cap is enforced before the NIF is entered — images
      larger than 50 MB are rejected with
      `{:error, %Quire.Engine.Error{code: :invalid_argument}}`.  The cap
      prevents dirty-scheduler memory pressure from an oversized image.
    * All NIF-bound calls are instrumented through
      `Quire.Engine.trace/4`.
  """

  @behaviour Quire.Ocr.Engine

  @max_image_bytes 50 * 1024 * 1024

  @doc """
  Runs OCR on an image binary.

  `image_bytes` is a PNG, JPEG, or TIFF. Returns recognised text spans
  with confidence and bounding-box metadata.

  ## Options

    * `:language` — ISO language code (default `"eng"`)
    * `:dpi` — override detected DPI
  """
  @impl Quire.Ocr.Engine
  def run(image_bytes, opts) when is_binary(image_bytes) and is_list(opts) do
    with :ok <- check_size(image_bytes) do
      Quire.Engine.trace(__MODULE__, :run, [byte_size(image_bytes), opts], fn ->
        language = Keyword.get(opts, :language, "eng")

        with {:ok, instance} <- Image.OCR.new(locale: language),
             {:ok, words} <- Image.OCR.recognize(instance, image_bytes) do
          # Convert Image.OCR word results to spans with map bounding box
          Enum.map(words, fn word ->
            {x1, y1, x2, y2} = word.bbox

            %{
              text: word.text,
              confidence: word.confidence,
              bbox: %{x: x1, y: y1, w: x2 - x1, h: y2 - y1}
            }
          end)
        else
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  @impl Quire.Ocr.Engine
  @doc """
  Returns the installed Tesseract and Leptonica versions.

  Delegates to `Image.OCR.tesseract_version/0` for the Tesseract version.
  Leptonica version is not exposed by the NIF and is returned as `"unknown"`.
  """
  def versions do
    %{tesseract: Image.OCR.tesseract_version(), leptonica: "unknown"}
  rescue
    _ -> %{tesseract: "unknown", leptonica: "unknown"}
  end

  @doc false
  def check do
    _ = Image.OCR.tesseract_version()
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── size enforcement ──────────────────────────────────────────────────────

  defp check_size(bytes) when byte_size(bytes) <= @max_image_bytes, do: :ok

  defp check_size(bytes) do
    {:error,
     %Quire.Engine.Error{
       engine: __MODULE__,
       operation: :run,
       code: :invalid_argument,
       message: "Image exceeds maximum size of #{div(@max_image_bytes, 1024 * 1024)} MB",
       detail: "received #{byte_size(bytes)} bytes"
     }}
  end
end
