defmodule Quire.ScanTest do
  use ExUnit.Case, async: true

  alias Quire.Scan
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp build_skewed_image(angle_deg) do
    {:ok, black} = Operation.black(500, 300)
    {:ok, white} = Operation.invert(black)
    {:ok, canvas} = Operation.embed(white, 100, 100, 800, 600, extend: :VIPS_EXTEND_BLACK)
    {:ok, doc} = Operation.invert(canvas)

    {:ok, rotated} =
      Operation.similarity(doc,
        angle: angle_deg,
        odx: 400.0,
        ody: 300.0,
        background: [255, 255, 255]
      )

    {:ok, png} = Image.write_to_buffer(rotated, ".png")
    png
  end

  defp gray_values(png_or_img) do
    img =
      case png_or_img do
        %Image{} = img -> img
        bytes when is_binary(bytes) ->
          {:ok, img} = Image.new_from_buffer(bytes)
          img
      end

    {:ok, gray} = Operation.colourspace(img, :VIPS_INTERPRETATION_B_W)
    {:ok, data} = Image.write_to_binary(gray)
    :binary.bin_to_list(data)
  end

  # ── image_to_pdf/2 ────────────────────────────────────────────────────

  describe "image_to_pdf/2" do
    test "produces a valid single-page PDF from a PNG" do
      png = build_skewed_image(0.0)

      assert {:ok, pdf} = Scan.image_to_pdf(png)
      assert binary_part(pdf, 0, 5) == "%PDF-"

      assert {:ok, doc} = Quire.Pdf.open(pdf)
      assert {:ok, 1} = Quire.Pdf.page_count(doc)
    end

    test "deskew: false leaves the image untransformed" do
      png = build_skewed_image(7.0)
      {:ok, img} = Image.new_from_buffer(png)
      w = Image.width(img)
      h = Image.height(img)

      assert {:ok, pdf} = Scan.image_to_pdf(png, deskew: false, contrast: :none)
      assert {:ok, doc} = Quire.Pdf.open(pdf)
      assert {:ok, 1} = Quire.Pdf.page_count(doc)

      # untransformed page keeps the source dimensions (1 px = 1 PDF pt)
      assert {:ok, [%{width: pw, height: ph}]} = page_geometries(pdf)
      assert pw == w * 1.0
      assert ph == h * 1.0
    end

    test "rejects non-image bytes" do
      assert {:error, {:invalid_image, _msg}} = Scan.image_to_pdf(<<"not an image">>)
    end

    test "rejects oversized input" do
      big = :binary.copy(<<0>>, 51 * 1024 * 1024)
      assert {:error, {:invalid_image, _msg}} = Scan.image_to_pdf(big)
    end

    test "rejects unknown contrast preset" do
      png = build_skewed_image(0.0)

      assert {:error, {:invalid_contrast, :sepia, _valid}} =
               Scan.image_to_pdf(png, contrast: :sepia)
    end
  end

  # ── detect_angle/1 + deskew/1 (the measurable T-080 bar) ─────────────

  describe "deskew" do
    test "detects and straightens a deliberately skewed image" do
      png = build_skewed_image(7.0)

      # Before: the dominant edge angle is the applied skew.
      assert {:ok, before} = Scan.detect_angle(png)
      assert abs(before) > 5.0
      assert abs(before) < 9.0

      # After: deskew rotates it back to axis-aligned.
      {:ok, img} = Image.new_from_buffer(png)
      assert {:ok, corrected, applied} = Scan.deskew(img)
      assert abs(applied - before) < 0.5

      {:ok, corrected_png} = Image.write_to_buffer(corrected, ".png")
      assert {:ok, after_angle} = Scan.detect_angle(corrected_png)
      assert abs(after_angle) < 1.0

      # The correction measurably reduces the skew.
      assert abs(after_angle) < abs(before)
    end

    test "detects negative skew too" do
      png = build_skewed_image(-7.0)
      assert {:ok, before} = Scan.detect_angle(png)
      assert abs(before) > 5.0
      assert abs(before) < 9.0

      {:ok, img} = Image.new_from_buffer(png)
      assert {:ok, corrected, _applied} = Scan.deskew(img)
      {:ok, corrected_png} = Image.write_to_buffer(corrected, ".png")
      assert {:ok, after_angle} = Scan.detect_angle(corrected_png)
      assert abs(after_angle) < 1.0
    end

    test "edge-less images report 0.0" do
      {:ok, black} = Operation.black(200, 150)
      {:ok, png} = Image.write_to_buffer(black, ".png")
      assert {:ok, 0.0} = Scan.detect_angle(png)
    end
  end

  # ── Contrast presets ──────────────────────────────────────────────────

  describe "apply_contrast/2" do
    setup do
      {:ok, xyz} = Operation.xyz(400, 300)
      {:ok, x} = Operation.extract_band(xyz, 0)
      {:ok, low} = Operation.linear(x, [100.0 / 399.0], [100.0])
      {:ok, low} = Operation.cast(low, :VIPS_FORMAT_UCHAR)
      {:ok, srgb} = Operation.colourspace(low, :VIPS_INTERPRETATION_sRGB)
      {:ok, png} = Image.write_to_buffer(srgb, ".png")
      {:ok, img} = Image.new_from_buffer(png)
      %{img: img}
    end

    test ":auto stretches to the full dynamic range", %{img: img} do
      assert {:ok, out} = Scan.apply_contrast(img, :auto)
      values = gray_values(out)
      assert Enum.min(values) <= 5
      assert Enum.max(values) >= 250
    end

    test ":bw binarises to exactly two levels", %{img: img} do
      assert {:ok, out} = Scan.apply_contrast(img, :bw)
      values = gray_values(out)
      assert Enum.uniq(values) |> Enum.sort() == [0, 255]
    end

    test ":high widens contrast about the midpoint", %{img: img} do
      assert {:ok, out} = Scan.apply_contrast(img, :high)
      values = gray_values(out)
      assert Enum.max(values) - Enum.min(values) > 100
    end

    test ":low narrows contrast", %{img: img} do
      assert {:ok, out} = Scan.apply_contrast(img, :low)
      values = gray_values(out)
      assert Enum.max(values) - Enum.min(values) < 100
    end

    test ":none returns the image unchanged", %{img: img} do
      assert {:ok, out} = Scan.apply_contrast(img, :none)
      assert out == img
    end
  end

  # ── T-014 guard: no filesystem or external scanner ───────────────────

  describe "T-014 guard conformance" do
    test "the module performs no File/Path/System.cmd operations" do
      source = File.read!("lib/quire/scan.ex")
      refute Regex.match?(~r{File\.|System\.cmd|System\.tmp_dir}, source)
      refute Regex.match?(~r{Path\.(?!t\(|extname|rootname|dirname)}, source)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp page_geometries(pdf_bytes) do
    {:ok, ref} = Quire.Storage.put(pdf_bytes, name: "scan.pdf", content_type: "application/pdf")
    Quire.Render.page_geometry(ref)
  end
end
