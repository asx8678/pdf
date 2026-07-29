defmodule Quire.Ocr.Tesseract do
  @moduledoc """
  OCR engine wrapping `image_ocr` NIF for Tesseract/Leptonica-based
  image-to-text extraction (§7.2).

  ## Status

  **Skeleton.** The `image_ocr` dependency is commented out in `mix.exs`
  pending the T-019 ADR decision on vendored-vs-Homebrew Tesseract
  (see `pdf-tuj`). When `image_ocr` is not available, every callback
  returns `{:error, %Quire.Engine.Error{code: :unavailable}}`.

  Once the ADR lands, uncomment `{:image_ocr, "== 0.2.0"}` in `mix.exs`,
  and this module will delegate to `ImageOcr.run/2` and friends.

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
      if Code.ensure_loaded?(ImageOcr) do
        Quire.Engine.trace(__MODULE__, :run, [byte_size(image_bytes), opts], fn ->
          case apply(ImageOcr, :run, [image_bytes, opts]) do
            {:ok, spans} -> spans
            {:error, reason} -> raise "image_ocr error: #{inspect(reason)}"
          end
        end)
      else
        {:error,
         %Quire.Engine.Error{
           engine: __MODULE__,
           operation: :run,
           code: :unavailable,
           message: "OCR engine not available \u2014 see pdf-tuj",
           detail: nil
         }}
      end
    end
  end

  @impl Quire.Ocr.Engine
  @doc """
  Returns the installed Tesseract and Leptonica versions.

  Delegates to `ImageOcr.versions/0` when the NIF is available; otherwise
  returns `"unknown"` for both components.
  """
  def versions do
    if Code.ensure_loaded?(ImageOcr) do
      apply(ImageOcr, :versions, [])
    else
      %{tesseract: "unknown", leptonica: "unknown"}
    end
  end

  @doc false
  def check do
    if Code.ensure_loaded?(ImageOcr) do
      _ = apply(ImageOcr, :versions, [])
      :ok
    else
      {:error, "image_ocr not loaded"}
    end
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
