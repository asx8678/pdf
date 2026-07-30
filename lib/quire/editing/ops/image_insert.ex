defmodule Quire.Editing.Ops.ImageInsert do
  @moduledoc """
  Validates, normalises, and applies an image.insert operation (§7.4, T-092).

  ## Flow

  1. **Magic-byte validation** — rejects uploads whose bytes don't match a
     known image format, regardless of file extension.
  2. **Format normalisation** — converts non-PNG/JPEG images (TIFF, BMP,
     WebP, HEIC, GIF) to PNG via libvips (`Vix`).  PNG and JPEG are left
     as-is since pdf.js can embed them natively.
  3. **Embedding** — the normalised data is returned to the caller so the
     pdf.js client hook can place it on the document page as an image XObject.
  4. **Manipulation metadata** — the op carries resize, rotate, opacity,
     z-index, and crop parameters for the client-side renderer.

  ## Valid image magic bytes

  See `known_format?/1` for the signature list.
  """

  # ── Magic-byte detection (T-092) ────────────────────────────────────────

  @known_signatures [
    {<<0xFF, 0xD8, 0xFF>>, :jpeg},
    {<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>, :png},
    {<<0x47, 0x49, 0x46, 0x38, 0x37, 0x61>>, :gif},
    {<<0x47, 0x49, 0x46, 0x38, 0x39, 0x61>>, :gif},
    {<<0x42, 0x4D>>, :bmp},
    {<<0x49, 0x49, 0x2A, 0x00>>, :tiff},
    {<<0x4D, 0x4D, 0x00, 0x2A>>, :tiff},
    {<<0x52, 0x49, 0x46, 0x46>>, :webp},
    {<<0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63>>, :heic},
    {<<0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x69, 0x66, 0x69>>, :heic}
  ]

  @doc """
  Returns the detected format atom (`:jpeg`, `:png`, `:gif`, `:bmp`, `:tiff`,
  `:webp`, `:heic`) or `:unknown` if the bytes don't match any known signature.
  """
  def detect_format(binary) when is_binary(binary) do
    Enum.find_value(@known_signatures, :unknown, fn {magic, format} ->
      if String.starts_with?(binary, magic), do: format
    end)
  end

  @doc """
  Returns `true` if `binary` starts with a known image-file magic byte
  sequence.
  """
  def known_format?(binary) when is_binary(binary) do
    detect_format(binary) != :unknown
  end

  # ── Normalisation via libvips ───────────────────────────────────────────

  @doc """
  Normalises image bytes to PNG (for non-transparent images) or JPEG.

  - PNG and JPEG input → returned as-is (no re-encode).
  - All other formats → decoded via `Vix.Vips.Image.new_from_buffer/2`
    and re-encoded as PNG.

  Returns `{:ok, format, normalised_bytes}` where `format` is `:png` or
  `:jpeg`, or `{:error, reason}`.
  """
  def normalise(bytes) when is_binary(bytes) do
    format = detect_format(bytes)

    case format do
      :png ->
        {:ok, :png, bytes}

      :jpeg ->
        {:ok, :jpeg, bytes}

      format when format in [:gif, :bmp, :tiff, :webp, :heic] ->
        normalise_via_vips(bytes)

      :unknown ->
        {:error, "Unknown or unsupported image format"}
    end
  end

  defp normalise_via_vips(bytes) do
    with {:ok, img} <- Vix.Vips.Image.new_from_buffer(bytes),
         {:ok, srgb} <- Vix.Vips.Operation.colourspace(img, :VIPS_INTERPRETATION_sRGB),
         {:ok, png} <- Vix.Vips.Image.write_to_buffer(srgb, ".png") do
      {:ok, :png, png}
    else
      {:error, reason} -> {:error, "Image normalisation failed: #{inspect(reason)}"}
    end
  end

  # ── Op application (T-092) ──────────────────────────────────────────────

  @doc """
  Validates and applies an `image.insert` operation.

  ## Expected op_data fields

    * `"bytes"` — raw image bytes (required)
    * `"page_index"` — target page (required)
    * `"rect"` — [x0, y0, x1, y1] in PDF points (required)
    * `"opacity"` — float 0.0–1.0 (optional, default 1.0)
    * `"rotate"` — rotation in degrees (optional, default 0)
    * `"z_index"` — integer stacking order (optional, default 0)

  ## Returns

    * `{:ok, enriched_op_data}` — original data augmented with normalised
      bytes and format, ready for client-side embedding.
    * `{:error, reason}` — validation or normalisation failure.
  """
  def apply(op_data, _context) do
    bytes = op_data["bytes"] || op_data[:bytes]

    cond do
      is_nil(bytes) ->
        {:error, "image.insert requires bytes"}

      not known_format?(bytes) ->
        {:error, "Upload does not match a known image format (magic bytes)"}

      true ->
        case normalise(bytes) do
          {:ok, format, normalised} ->
            enriched =
              op_data
              |> Map.drop(["bytes", :bytes])
              |> Map.put("normalised_bytes", Base.encode64(normalised))
              |> Map.put("normalised_format", Atom.to_string(format))

            {:ok, enriched}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Computes the inverse of `image.insert`.

  Since no `image.delete` counterpart exists in the op catalogue,
  returns a `restore_revision` placeholder (Phase 0 behaviour).
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
