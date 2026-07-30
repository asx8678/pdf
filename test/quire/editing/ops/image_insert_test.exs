defmodule Quire.Editing.Ops.ImageInsertTest do
  use ExUnit.Case, async: true

  alias Quire.Editing.Ops.ImageInsert

  describe "detect_format/1" do
    test "detects JPEG" do
      assert ImageInsert.detect_format(<<0xFF, 0xD8, 0xFF, 0xE0>>) == :jpeg
    end

    test "detects PNG" do
      assert ImageInsert.detect_format(
               <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00>>
             ) == :png
    end

    test "detects GIF87a" do
      assert ImageInsert.detect_format(<<0x47, 0x49, 0x46, 0x38, 0x37, 0x61>>) == :gif
    end

    test "detects GIF89a" do
      assert ImageInsert.detect_format(<<0x47, 0x49, 0x46, 0x38, 0x39, 0x61>>) == :gif
    end

    test "detects BMP" do
      assert ImageInsert.detect_format(<<0x42, 0x4D, 0x36, 0x00>>) == :bmp
    end

    test "detects TIFF (little-endian)" do
      assert ImageInsert.detect_format(<<0x49, 0x49, 0x2A, 0x00>>) == :tiff
    end

    test "detects TIFF (big-endian)" do
      assert ImageInsert.detect_format(<<0x4D, 0x4D, 0x00, 0x2A>>) == :tiff
    end

    test "detects WebP" do
      assert ImageInsert.detect_format(
               <<0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50>>
             ) == :webp
    end

    test "detects HEIC" do
      assert ImageInsert.detect_format(
               <<0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63>>
             ) == :heic
    end

    test "returns :unknown for random bytes" do
      assert ImageInsert.detect_format(<<0xDE, 0xAD, 0xBE, 0xEF>>) == :unknown
    end

    test "returns :unknown for empty binary" do
      assert ImageInsert.detect_format(<<"">>) == :unknown
    end

    test "returns :unknown for text content" do
      assert ImageInsert.detect_format("this is not an image") == :unknown
    end
  end

  describe "known_format?/1" do
    test "returns true for a known magic byte sequence" do
      assert ImageInsert.known_format?(<<0xFF, 0xD8, 0xFF, 0xE0>>)
    end

    test "returns false for unknown bytes" do
      refute ImageInsert.known_format?(<<0x00, 0x01, 0x02, 0x03>>)
    end
  end

  describe "normalise/1" do
    test "passes PNG bytes through unchanged" do
      png =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
          0x44, 0x52>>

      assert {:ok, :png, ^png} = ImageInsert.normalise(png)
    end

    test "passes JPEG bytes through unchanged" do
      jpeg = <<0xFF, 0xD8, 0xFF, 0xE0>>

      assert {:ok, :jpeg, ^jpeg} = ImageInsert.normalise(jpeg)
    end

    test "returns error for unknown format" do
      assert {:error, _reason} = ImageInsert.normalise(<<0x00, 0x01, 0x02, 0x03>>)
    end

    test "normalises WebP to PNG via vix" do
      # Generate a 2×2 red WebP via vix, then verify normalise/1 converts it
      # to PNG (proving the vix pipeline handles non-PNG/JPEG input).
      webp = generate_webp_bytes()
      assert ImageInsert.detect_format(webp) == :webp

      assert {:ok, :png, png_bytes} = ImageInsert.normalise(webp)
      assert byte_size(png_bytes) > 0
      assert ImageInsert.detect_format(png_bytes) == :png
    end
  end

  describe "apply/2" do
    test "returns error when bytes are missing" do
      assert {:error, "image.insert requires bytes"} = ImageInsert.apply(%{}, nil)
    end

    test "returns error for unknown format" do
      op_data = %{
        "bytes" => <<0xDE, 0xAD, 0xBE, 0xEF>>,
        "page_index" => 0,
        "rect" => [0, 0, 100, 100]
      }

      assert {:error, msg} = ImageInsert.apply(op_data, nil)
      assert msg =~ "known image format"
    end

    test "enriches PNG op_data with normalised bytes" do
      png = valid_png_bytes()

      op_data = %{
        "bytes" => png,
        "page_index" => 0,
        "rect" => [10, 20, 210, 220],
        "opacity" => 0.8
      }

      assert {:ok, enriched} = ImageInsert.apply(op_data, nil)

      # Original bytes removed, normalised bytes added
      refute Map.has_key?(enriched, "bytes")
      assert Map.has_key?(enriched, "normalised_bytes")
      assert enriched["normalised_format"] == "png"
      assert enriched["page_index"] == 0
      assert enriched["rect"] == [10, 20, 210, 220]
      assert enriched["opacity"] == 0.8

      # normalised_bytes should be valid base64
      assert {:ok, decoded} = Base.decode64(enriched["normalised_bytes"])
      assert byte_size(decoded) > 0
    end

    test "normalises WebP bytes in apply pipeline" do
      webp = generate_webp_bytes()
      op_data = %{"bytes" => webp, "page_index" => 1, "rect" => [0, 0, 200, 100]}

      assert {:ok, enriched} = ImageInsert.apply(op_data, nil)
      assert enriched["normalised_format"] == "png"

      {:ok, decoded} = Base.decode64(enriched["normalised_bytes"])
      assert ImageInsert.detect_format(decoded) == :png
    end

    test "accepts atom keys as well as string keys" do
      png = valid_png_bytes()
      op_data = %{bytes: png, page_index: 0, rect: [0, 0, 50, 50]}

      assert {:ok, enriched} = ImageInsert.apply(op_data, nil)
      assert enriched["normalised_format"] == "png"
    end
  end

  describe "invert/2" do
    test "returns restore_revision placeholder" do
      assert {:ok, {:restore_revision, nil}} = ImageInsert.invert(%{}, nil)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp valid_png_bytes do
    # Build a minimal valid PNG: 1x1 red pixel
    width = 1
    height = 1
    bands = 3
    format = :VIPS_FORMAT_UCHAR
    pixels = <<255, 0, 0>>

    {:ok, img} = Vix.Vips.Image.new_from_binary(pixels, width, height, bands, format)
    {:ok, png} = Vix.Vips.Image.write_to_buffer(img, ".png")
    png
  end

  defp generate_webp_bytes do
    {width, height, bands, format, pixels} =
      {2, 2, 3, :VIPS_FORMAT_UCHAR,
       <<
         255,
         0,
         0,
         0,
         255,
         0,
         0,
         0,
         255,
         255,
         255,
         0
       >>}

    {:ok, img} = Vix.Vips.Image.new_from_binary(pixels, width, height, bands, format)
    {:ok, webp} = Vix.Vips.Image.write_to_buffer(img, ".webp")
    webp
  end
end
