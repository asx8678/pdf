defmodule Quire.Gate3Test do
  use ExUnit.Case, async: false

  alias Quire.Workers.TransformWorker

  @page_count 200

  # ── Helpers ────────────────────────────────────────────────────────────

  # Generate a 200-page PDF where each page is labeled with "Page N" text.
  defp labeled_pdf(count) do
    {:ok, doc} = ExPdfium.new()

    doc =
      Enum.reduce(1..count, doc, fn i, acc ->
        {:ok, acc} = ExPdfium.add_page(acc, {612.0, 792.0})
        {:ok, acc} = ExPdfium.draw_text(acc, i - 1, {20.0, 750.0}, "Page #{i}", size: 14)
        acc
      end)

    {:ok, bytes} = ExPdfium.save_to_bytes(doc)
    :ok = ExPdfium.close(doc)
    bytes
  end

  # Generate a plain N-page PDF (no text, just blank pages).
  defp blank_pdf(count) do
    {:ok, doc} = ExPdfium.new()

    doc =
      Enum.reduce(1..count, doc, fn _, acc ->
        {:ok, acc} = ExPdfium.add_page(acc, {612.0, 792.0})
        acc
      end)

    {:ok, bytes} = ExPdfium.save_to_bytes(doc)
    :ok = ExPdfium.close(doc)
    bytes
  end

  # Store PDF bytes and return the ref.
  defp store(pdf_bytes, name) do
    {:ok, ref} = Quire.Storage.put(pdf_bytes, name: name)
    ref
  end

  # Extract text from a specific page index (returns the raw text string).
  defp page_text(bytes, idx) do
    {:ok, doc} = ExPdfium.open_blob(bytes)

    try do
      case ExPdfium.extract_text(doc, idx) do
        {:ok, text} -> String.trim(text)
        {:error, _} -> ""
      end
    after
      ExPdfium.close(doc)
    end
  end

  # Get the CropBox for a page, returning nil when not set.
  defp crop_box(bytes, idx) do
    {:ok, doc} = ExPdfium.open_blob(bytes)

    try do
      {:ok, info} = ExPdfium.page_info(doc, idx)
      info.boxes.crop
    after
      ExPdfium.close(doc)
    end
  end

  # Get the MediaBox for a page.
  defp media_box(bytes, idx) do
    {:ok, doc} = ExPdfium.open_blob(bytes)

    try do
      {:ok, info} = ExPdfium.page_info(doc, idx)
      info.boxes.media
    after
      ExPdfium.close(doc)
    end
  end

  # Get page count from raw bytes.
  defp page_count(bytes) do
    {:ok, doc} = ExPdfium.open_blob(bytes)

    try do
      {:ok, count} = ExPdfium.page_count(doc)
      count
    after
      ExPdfium.close(doc)
    end
  end

  # ── Fixture ────────────────────────────────────────────────────────────

  setup do
    ref =
      @page_count
      |> labeled_pdf()
      |> store("gate3_200p.pdf")

    %{ref: ref}
  end

  # ── 1. Reorder: reverse first 50 pages ─────────────────────────────────

  describe "page_splice reorder" do
    test "reverses the first 50 pages and keeps the rest in order", %{ref: ref} do
      {:ok, bytes} = Quire.Storage.get(ref)

      # Build page_order: [49, 48, ..., 0, 50, 51, ..., 199]
      reordered =
        Enum.to_list(49..0//-1) ++ Enum.to_list(50..(@page_count - 1))

      pages = Enum.map(reordered, fn idx -> {idx, nil, nil} end)

      assert {:ok, new_bytes} = TransformWorker.page_splice(bytes, pages)

      # Verify page count unchanged
      assert page_count(new_bytes) == @page_count

      # Spot-check page labels to confirm order
      # Page 0 should be "Page 50" (original index 49, 0-based → label 50)
      assert page_text(new_bytes, 0) =~ "Page 50"
      # Page 49 should be "Page 1" (original index 0)
      assert page_text(new_bytes, 49) =~ "Page 1"
      # Page 50 should be "Page 51" (unchanged)
      assert page_text(new_bytes, 50) =~ "Page 51"
      # Page 199 should be "Page 200"
      assert page_text(new_bytes, 199) =~ "Page 200"

      # Deep verify first 10 reversed
      for i <- 0..9 do
        expected = "Page #{50 - i}"

        assert page_text(new_bytes, i) =~ expected,
               "page #{i} should contain '#{expected}' after reverse"
      end
    end

    test "page_splice with identity order returns identical page count and content", %{ref: ref} do
      {:ok, bytes} = Quire.Storage.get(ref)

      # Identity order: [0, 1, 2, ..., 199]
      pages = Enum.map(0..(@page_count - 1), fn idx -> {idx, nil, nil} end)

      assert {:ok, new_bytes} = TransformWorker.page_splice(bytes, pages)

      assert page_count(new_bytes) == @page_count

      # Spot-check that content matches
      assert page_text(new_bytes, 0) =~ "Page 1"
      assert page_text(new_bytes, 99) =~ "Page 100"
      assert page_text(new_bytes, 199) =~ "Page 200"
    end

    test "page_splice with subset yields fewer pages", %{ref: ref} do
      {:ok, bytes} = Quire.Storage.get(ref)

      # Extract only the first 10 pages
      pages = Enum.map(0..9, fn idx -> {idx, nil, nil} end)

      assert {:ok, new_bytes} = TransformWorker.page_splice(bytes, pages)
      assert page_count(new_bytes) == 10
    end

    test "page_splice with duplicate pages creates a larger document", %{ref: ref} do
      {:ok, bytes} = Quire.Storage.get(ref)

      # Repeat page 0 three times, then page 1 once
      pages = [
        {0, nil, nil},
        {0, nil, nil},
        {0, nil, nil},
        {1, nil, nil}
      ]

      assert {:ok, new_bytes} = TransformWorker.page_splice(bytes, pages)
      assert page_count(new_bytes) == 4

      # All three copies of page 0 should have "Page 1"
      assert page_text(new_bytes, 0) =~ "Page 1"
      assert page_text(new_bytes, 1) =~ "Page 1"
      assert page_text(new_bytes, 2) =~ "Page 1"
      assert page_text(new_bytes, 3) =~ "Page 2"
    end
  end

  # ── 2. Crop ────────────────────────────────────────────────────────────

  describe "crop operations via TransformWorker" do
    test "perform_crop sets CropBox shrunk by margins from MediaBox" do
      pdf_bytes = blank_pdf(3)
      {:ok, _ref} = Quire.Storage.put(pdf_bytes, name: "crop_3p.pdf")

      # Crop with 20pt margins on all sides
      args = %{
        "page_order" => [0, 1, 2],
        "top" => 20,
        "bottom" => 20,
        "left" => 20,
        "right" => 20
      }

      assert {:ok, cropped} = TransformWorker.perform_crop(pdf_bytes, args)

      # Check page count preserved
      assert page_count(cropped) == 3

      # Verify CropBox is set and differs from MediaBox
      media = media_box(pdf_bytes, 0)
      crop = crop_box(cropped, 0)
      assert crop != nil, "CropBox should be set after perform_crop"
      assert crop.left >= media.left + 19
      assert crop.bottom >= media.bottom + 19
      assert crop.right <= media.right - 19
      assert crop.top <= media.top - 19
    end

    test "perform_remove_crop resets CropBox to equal MediaBox" do
      pdf_bytes = blank_pdf(3)

      # First crop
      crop_args = %{
        "page_order" => [0, 1, 2],
        "top" => 40,
        "bottom" => 40,
        "left" => 40,
        "right" => 40
      }

      assert {:ok, cropped} = TransformWorker.perform_crop(pdf_bytes, crop_args)
      crop = crop_box(cropped, 0)
      media = media_box(pdf_bytes, 0)
      refute crop == nil
      # Crop is shrunk
      assert crop.left > media.left

      # Now remove crop (undo)
      remove_args = %{"page_order" => [0, 1, 2]}
      assert {:ok, uncropped} = TransformWorker.perform_remove_crop(cropped, remove_args)

      restored_crop = crop_box(uncropped, 0)
      restored_media = media_box(uncropped, 0)
      assert restored_crop != nil

      assert_in_delta restored_crop.left,
                      restored_media.left,
                      0.1,
                      "CropBox left should match MediaBox left after remove crop"

      assert_in_delta restored_crop.right, restored_media.right, 0.1
      assert_in_delta restored_crop.bottom, restored_media.bottom, 0.1
      assert_in_delta restored_crop.top, restored_media.top, 0.1
    end

    test "multiple crop operations — crop, undo, re-crop" do
      pdf_bytes = blank_pdf(5)
      media_before = media_box(pdf_bytes, 0)

      # 1. First crop: 10pt margins on all pages
      crop1 = %{
        "page_order" => [0, 1, 2, 3, 4],
        "top" => 10,
        "bottom" => 10,
        "left" => 10,
        "right" => 10
      }

      assert {:ok, after_crop1} = TransformWorker.perform_crop(pdf_bytes, crop1)
      crop1_box = crop_box(after_crop1, 0)
      assert crop1_box.left == 10.0
      assert crop1_box.bottom == 10.0
      assert crop1_box.right == 602.0
      assert crop1_box.top == 782.0

      # 2. Remove crop (undo)
      remove = %{"page_order" => [0, 1, 2, 3, 4]}
      assert {:ok, after_remove} = TransformWorker.perform_remove_crop(after_crop1, remove)
      removed_crop = crop_box(after_remove, 0)
      assert_in_delta removed_crop.left, media_before.left, 0.1

      # 3. Re-crop with different margins
      crop2 = %{
        "page_order" => [0, 1, 2, 3, 4],
        "top" => 30,
        "bottom" => 30,
        "left" => 50,
        "right" => 50
      }

      assert {:ok, after_crop2} = TransformWorker.perform_crop(after_remove, crop2)
      crop2_box = crop_box(after_crop2, 0)
      assert crop2_box.left == 50.0
      assert crop2_box.bottom == 30.0
      assert crop2_box.right == 562.0
      assert crop2_box.top == 762.0
    end
  end

  # ── 3. Edge cases ──────────────────────────────────────────────────────

  describe "crop edge cases" do
    test "single page crop (selected = [1])" do
      pdf_bytes = blank_pdf(5)
      {:ok, _ref} = Quire.Storage.put(pdf_bytes, name: "single_crop.pdf")

      # Crop only page index 1 (second page)
      single_args = %{
        "page_order" => [1],
        "top" => 50,
        "bottom" => 50,
        "left" => 50,
        "right" => 50
      }

      assert {:ok, single_cropped} = TransformWorker.perform_crop(pdf_bytes, single_args)

      # The result has only 1 page (since page_order is only [1])
      assert page_count(single_cropped) == 1

      crop = crop_box(single_cropped, 0)
      assert crop != nil
      assert crop.left == 50.0
      assert crop.bottom == 50.0
    end

    test "all pages crop (scope = all pages in page_order)" do
      pdf_bytes = blank_pdf(10)

      args = %{
        "page_order" => Enum.to_list(0..9),
        "top" => 25,
        "bottom" => 25,
        "left" => 30,
        "right" => 30
      }

      assert {:ok, cropped} = TransformWorker.perform_crop(pdf_bytes, args)

      # Every page should have the same CropBox
      for idx <- 0..9 do
        crop = crop_box(cropped, idx)
        assert crop != nil, "page #{idx} should have CropBox"
        assert crop.left == 30.0
        assert crop.bottom == 25.0
        assert crop.right == 582.0
        assert crop.top == 767.0
      end
    end

    test "odd/even page selection crop" do
      pdf_bytes = blank_pdf(6)

      # Crop odd pages (0, 2, 4) with large margins
      odd_args = %{
        "page_order" => [0, 2, 4],
        "top" => 60,
        "bottom" => 60,
        "left" => 60,
        "right" => 60
      }

      assert {:ok, odd_cropped} = TransformWorker.perform_crop(pdf_bytes, odd_args)

      # Result has 3 pages (only the odd ones)
      assert page_count(odd_cropped) == 3

      for idx <- 0..2 do
        crop = crop_box(odd_cropped, idx)
        assert crop != nil
        assert crop.left == 60.0
      end

      # Crop even pages (1, 3, 5) with different margins
      even_args = %{
        "page_order" => [1, 3, 5],
        "top" => 20,
        "bottom" => 20,
        "left" => 80,
        "right" => 40
      }

      assert {:ok, even_cropped} = TransformWorker.perform_crop(pdf_bytes, even_args)

      assert page_count(even_cropped) == 3

      for idx <- 0..2 do
        crop = crop_box(even_cropped, idx)
        assert crop != nil
        assert crop.left == 80.0
      end
    end

    test "undo after each step restores prior state" do
      pdf_bytes = blank_pdf(4)
      media_orig = media_box(pdf_bytes, 0)

      # Step 1: Crop with 10pt margins
      step1 = %{
        "page_order" => [0, 1, 2, 3],
        "top" => 10,
        "bottom" => 10,
        "left" => 10,
        "right" => 10
      }

      assert {:ok, s1} = TransformWorker.perform_crop(pdf_bytes, step1)
      assert crop_box(s1, 0).left == 10.0

      # Undo step 1
      undo = %{"page_order" => [0, 1, 2, 3]}
      assert {:ok, s1_undo} = TransformWorker.perform_remove_crop(s1, undo)
      assert_in_delta crop_box(s1_undo, 0).left, media_orig.left, 0.1

      # Step 2: Crop with 50pt margins
      step2 = %{
        "page_order" => [0, 1, 2, 3],
        "top" => 50,
        "bottom" => 50,
        "left" => 50,
        "right" => 50
      }

      assert {:ok, s2} = TransformWorker.perform_crop(s1_undo, step2)
      assert crop_box(s2, 0).left == 50.0

      # Undo step 2
      assert {:ok, s2_undo} = TransformWorker.perform_remove_crop(s2, undo)
      assert_in_delta crop_box(s2_undo, 0).left, media_orig.left, 0.1

      # Step 3: Crop with 100pt margins (asymmetric)
      step3 = %{
        "page_order" => [0, 1, 2, 3],
        "top" => 100,
        "bottom" => 40,
        "left" => 20,
        "right" => 80
      }

      assert {:ok, s3} = TransformWorker.perform_crop(s2_undo, step3)
      assert crop_box(s3, 0).left == 20.0
      assert crop_box(s3, 0).top == 692.0
      assert crop_box(s3, 0).right == 532.0

      # Undo step 3
      assert {:ok, s3_undo} = TransformWorker.perform_remove_crop(s3, undo)
      assert_in_delta crop_box(s3_undo, 0).left, media_orig.left, 0.1
    end
  end

  # ── 4. Full pipeline: reorder + crop + undo + re-crop ──────────────────

  describe "full pipeline" do
    test "200-page document: reorder, crop, undo, re-crop", %{ref: ref} do
      {:ok, bytes} = Quire.Storage.get(ref)

      # === Phase 1: Reorder (reverse first 50) ===
      reordered =
        Enum.to_list(49..0//-1) ++ Enum.to_list(50..(@page_count - 1))

      pages = Enum.map(reordered, fn idx -> {idx, nil, nil} end)
      assert {:ok, reordered_bytes} = TransformWorker.page_splice(bytes, pages)

      assert page_count(reordered_bytes) == @page_count,
             "Page count must remain 200 after reorder"

      # Verify first page is original page 50
      assert page_text(reordered_bytes, 0) =~ "Page 50"
      assert page_text(reordered_bytes, 49) =~ "Page 1"

      # === Phase 2: Crop ===
      crop_args = %{
        "page_order" => Enum.to_list(0..(@page_count - 1)),
        "top" => 36,
        "bottom" => 36,
        "left" => 36,
        "right" => 36
      }

      assert {:ok, cropped_bytes} = TransformWorker.perform_crop(reordered_bytes, crop_args)

      assert page_count(cropped_bytes) == @page_count

      # Verify CropBox is set on every page
      for idx <- 0..9 do
        crop = crop_box(cropped_bytes, idx)
        assert crop != nil, "page #{idx} should have CropBox after crop"
        assert_in_delta crop.left, 36.0, 0.1
        assert_in_delta crop.right, 576.0, 0.1
      end

      # === Phase 3: Undo (remove crop) ===
      remove_args = %{
        "page_order" => Enum.to_list(0..(@page_count - 1))
      }

      assert {:ok, uncropped_bytes} =
               TransformWorker.perform_remove_crop(cropped_bytes, remove_args)

      assert page_count(uncropped_bytes) == @page_count

      # Verify CropBox restored to MediaBox
      for idx <- 0..9 do
        media = media_box(bytes, idx)
        crop_after = crop_box(uncropped_bytes, idx)
        assert crop_after != nil
        assert_in_delta crop_after.left, media.left, 0.1
        assert_in_delta crop_after.right, media.right, 0.1
      end

      # Verify content preserved (page text still correct after undo)
      assert page_text(uncropped_bytes, 0) =~ "Page 50"
      assert page_text(uncropped_bytes, 199) =~ "Page 200"

      # === Phase 4: Re-crop with different margins ===
      recrop_args = %{
        "page_order" => Enum.to_list(0..(@page_count - 1)),
        "top" => 72,
        "bottom" => 72,
        "left" => 72,
        "right" => 72
      }

      assert {:ok, recropped_bytes} =
               TransformWorker.perform_crop(uncropped_bytes, recrop_args)

      assert page_count(recropped_bytes) == @page_count

      # Verify new CropBox
      for idx <- 0..9 do
        crop = crop_box(recropped_bytes, idx)
        assert crop != nil
        assert_in_delta crop.left, 72.0, 0.1
        assert_in_delta crop.right, 540.0, 0.1
      end
    end
  end

  # ── 5. Storage + Revision fixture pattern ──────────────────────────────

  describe "Storage.put + revision fixture" do
    test "stored PDF can be read back with correct page count" do
      pdf_bytes = labeled_pdf(10)
      ref = store(pdf_bytes, "ten.pdf")

      {:ok, stored_bytes} = Quire.Storage.get(ref)

      assert page_count(stored_bytes) == 10

      assert page_text(stored_bytes, 0) =~ "Page 1"
      assert page_text(stored_bytes, 9) =~ "Page 10"
    end

    test "page_splice on stored document preserves round-trip integrity" do
      pdf_bytes = labeled_pdf(5)
      ref = store(pdf_bytes, "five.pdf")
      {:ok, stored_bytes} = Quire.Storage.get(ref)

      # Reverse order
      pages = Enum.map([4, 3, 2, 1, 0], fn idx -> {idx, nil, nil} end)
      assert {:ok, spliced} = TransformWorker.page_splice(stored_bytes, pages)

      new_ref = store(spliced, "five_reversed.pdf")
      {:ok, loaded} = Quire.Storage.get(new_ref)

      assert page_text(loaded, 0) =~ "Page 5"
      assert page_text(loaded, 4) =~ "Page 1"
    end
  end
end
