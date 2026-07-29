defmodule Quire.Ocr.Engine do
  @moduledoc """
  OCR engine behaviour — image-to-text extraction (§7.2).

  Primary implementation wraps `image_ocr` NIF with `vix` image
  preprocessing. Each call operates on an image binary and returns
  recognised text with positional metadata.
  """

  @doc """
  Runs OCR on an image binary.

  `image_bytes` is a PNG, JPEG, or TIFF. Returns spans with recognised
  text, confidence, and bounding box per span.

  Options:
    - `:language` — ISO language code (default `"eng"`)
    - `:dpi` — override detected DPI
  """
  @callback run(image_bytes :: binary(), opts :: keyword()) ::
              {:ok, list(map())} | {:error, term()}

  @doc """
  Returns the installed Tesseract and Leptonica versions.
  """
  @callback versions() :: %{
              required(:tesseract) => String.t(),
              required(:leptonica) => String.t()
            }
end
