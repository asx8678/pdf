defmodule Quire.CompressTest do
  use ExUnit.Case, async: true

  alias Quire.Compress

  @fixtures Path.expand("../fixtures/pdfs", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # Catalog keys of a (pdfium-normalised) PDF, read via lopdf
  defp catalog_keys(bytes) do
    {:ok, q} = Quire.Pdf.open(bytes)
    {:ok, catalog} = Quire.Pdf.get_object(q, 1)
    Map.keys(catalog)
  end

  # ── Accessibility preservation ─────────────────────────────────────────

  describe "tagged-PDF accessibility" do
    test "/StructTreeRoot and /MarkInfo survive every preset by default" do
      tagged = fixture("tagged_accessible.pdf")

      for preset <- [:low, :medium, :high, :custom] do
        assert {:ok, out} = Compress.compress(tagged, preset: preset)
        keys = catalog_keys(out)
        assert "/StructTreeRoot" in keys, "preset #{preset} dropped StructTreeRoot"
        assert "/MarkInfo" in keys, "preset #{preset} dropped MarkInfo"
      end
    end

    test "remove_accessibility: true strips both keys (explicit opt-in)" do
      tagged = fixture("tagged_accessible.pdf")

      assert {:ok, out} =
               Compress.compress(tagged, preset: :medium, remove_accessibility: true)

      keys = catalog_keys(out)
      refute "/StructTreeRoot" in keys
      refute "/MarkInfo" in keys
    end
  end

  # ── Preset distinctness ────────────────────────────────────────────────

  describe "presets" do
    test "low/medium/high/custom map to distinct output sizes" do
      images = fixture("50mb_images.pdf")

      assert {:ok, low} = Compress.compress(images, preset: :low)
      assert {:ok, medium} = Compress.compress(images, preset: :medium)
      assert {:ok, high} = Compress.compress(images, preset: :high)

      assert {:ok, custom} =
               Compress.compress(images, preset: :custom, quality: 30, max_width: 512)

      sizes = %{
        low: byte_size(low),
        medium: byte_size(medium),
        high: byte_size(high),
        custom: byte_size(custom)
      }

      assert sizes.low > sizes.medium
      assert sizes.medium > sizes.high
      assert sizes.custom < sizes.high
      # every preset actually reduces the 50 MB source
      assert byte_size(high) < byte_size(images)
    end
  end

  # ── Structural rebuild ─────────────────────────────────────────────────

  describe "output structure" do
    test "rebuilds with object streams and xref streams" do
      images = fixture("50mb_images.pdf")
      assert {:ok, out} = Compress.compress(images, preset: :high)
      assert :binary.match(out, "/ObjStm") != :nomatch
      assert :binary.match(out, "/XRef") != :nomatch
    end

    test "output is a valid PDF that reopens in PDFium" do
      images = fixture("50mb_images.pdf")
      assert {:ok, out} = Compress.compress(images, preset: :high)

      assert binary_part(out, 0, 5) == "%PDF-"
      assert {:ok, doc} = ExPdfium.open(out)
      assert {:ok, 250} = ExPdfium.page_count(doc)
    end

    test "images are actually recompressed (custom preset downscales)" do
      images = fixture("50mb_images.pdf")
      # 512 px cap forces downscaling of the 1000 px images
      assert {:ok, out} = Compress.compress(images, preset: :custom, quality: 50, max_width: 512)

      {:ok, src} = ExPdfium.open(images)
      {:ok, src_imgs} = ExPdfium.images(src, 0)
      {:ok, src_bm} = ExPdfium.image_data(src, 0, hd(src_imgs).index)

      {:ok, dst} = ExPdfium.open(out)
      {:ok, dst_imgs} = ExPdfium.images(dst, 0)
      {:ok, dst_bm} = ExPdfium.image_data(dst, 0, hd(dst_imgs).index)

      # downscaled image has fewer pixels
      assert byte_size(dst_bm.data) < byte_size(src_bm.data)
      assert dst_bm.width < src_bm.width
    end
  end
end
