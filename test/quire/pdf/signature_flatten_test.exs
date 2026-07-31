defmodule Quire.Pdf.SignatureFlattenTest do
  use ExUnit.Case, async: true

  alias Quire.Pdf.SignatureFlatten

  @fixture_dir Path.expand("../../fixtures/pdfs", __DIR__)
  @png_path Path.expand("../../fixtures/images/transparent.png", __DIR__)

  # The hand-built string-concatenation fixtures in generate_fixtures.exs are
  # not accepted by the lopdf NIF parser (see T-115 notes), so normalise them
  # through PDFium first — the same path pdf_test.exs uses for its inputs.
  defp normalized_fixture(name) do
    {:ok, doc} = ExPdfium.open(File.read!(Path.join(@fixture_dir, name)))
    {:ok, bytes} = ExPdfium.save_to_bytes(doc)
    bytes
  end

  defp render_ok?(bytes, page \\ 0) do
    {:ok, ref} = Quire.Storage.put(bytes, name: "test.pdf")
    match?({:ok, _}, Quire.Render.Pdfium.render_page(ref, page, dpi: 72))
  end

  describe "place/4" do
    test "embeds a signature PNG as a page XObject on a plain page" do
      pdf = normalized_fixture("simple_text.pdf")
      png = File.read!(@png_path)

      assert {:ok, placed} = SignatureFlatten.place(pdf, 0, [72.0, 72.0, 200.0, 100.0], png)
      assert byte_size(placed) > byte_size(pdf)
      assert render_ok?(placed)

      # The placed doc must still open in lopdf with the XObject resource present
      assert {:ok, doc} = Quire.Pdf.open(placed)
      assert {:ok, catalog} = Quire.Pdf.catalog(doc)
      assert {:ref, pages_num, _} = catalog["/Pages"]
      assert {:ok, pages} = Quire.Pdf.get_object(doc, {pages_num, 0})
      assert {:ref, kid, _} = hd(Map.get(pages, "/Kids"))
      assert {:ok, page} = Quire.Pdf.get_object(doc, {kid, 0})
      assert {:ok, resources} = resource_map(doc, page)
      assert {:ref, img_num, _} = get_in(resources, ["/XObject", "/ImSig1"])
      assert {:ok, {:stream, img_dict, _data}} = Quire.Pdf.get_object(doc, {img_num, 0})
      assert img_dict["/Subtype"] == {:name, "Image"}
      assert img_dict["/Width"] == 50
      assert img_dict["/Height"] == 20

      # Placement content stream must be appended to the page contents
      contents = Map.get(page, "/Contents")
      assert is_list(contents)
      assert length(contents) == 2
    end

    test "places on every page of a rotated multi-page document" do
      pdf = normalized_fixture("rotated_pages.pdf")
      png = File.read!(@png_path)

      assert {:ok, placed} = SignatureFlatten.place(pdf, 0, [72.0, 72.0, 200.0, 100.0], png)
      assert render_ok?(placed, 0)

      assert {:ok, placed} = SignatureFlatten.place(pdf, 1, [100.0, 50.0, 250.0, 90.0], png)
      assert render_ok?(placed, 1)

      assert {:ok, placed} = SignatureFlatten.place(pdf, 2, [30.0, 300.0, 180.0, 340.0], png)
      assert render_ok?(placed, 2)

      assert {:ok, placed} = SignatureFlatten.place(pdf, 3, [200.0, 200.0, 320.0, 260.0], png)
      assert render_ok?(placed, 3)
    end

    test "places on a cropped page with a non-zero origin" do
      pdf = normalized_fixture("cropped_nonzero_origin.pdf")
      png = File.read!(@png_path)

      assert {:ok, placed} = SignatureFlatten.place(pdf, 0, [50.0, 60.0, 150.0, 100.0], png)
      assert render_ok?(placed)
    end

    test "handles /Resources stored as an indirect reference" do
      pdf = normalized_fixture("simple_text.pdf")
      png = File.read!(@png_path)

      # Rewrite the page so /Resources points at a shared indirect object
      {:ok, doc} = Quire.Pdf.open(pdf)
      {:ok, catalog} = Quire.Pdf.catalog(doc)
      assert {:ref, pages_num, _} = catalog["/Pages"]
      assert {:ok, pages} = Quire.Pdf.get_object(doc, {pages_num, 0})
      assert {:ref, kid, _} = hd(Map.get(pages, "/Kids"))
      assert {:ok, page} = Quire.Pdf.get_object(doc, {kid, 0})
      assert {:ok, res_num} = Quire.Pdf.allocate_object_id(doc)
      assert :ok = Quire.Pdf.set_object(doc, {res_num, 0}, Map.get(page, "/Resources", %{}))

      assert :ok =
               Quire.Pdf.set_object(
                 doc,
                 {kid, 0},
                 Map.put(page, "/Resources", {:ref, res_num, 0})
               )

      assert {:ok, indirect} = Quire.Pdf.save(doc)

      assert {:ok, placed} = SignatureFlatten.place(indirect, 0, [72.0, 72.0, 200.0, 100.0], png)
      assert render_ok?(placed)

      # The shared resources object now carries the XObject
      assert {:ok, doc} = Quire.Pdf.open(placed)
      assert {:ok, resources} = Quire.Pdf.get_object(doc, {res_num, 0})
      assert {:ref, img_num, _} = get_in(resources, ["/XObject", "/ImSig1"])

      assert {:ok, {:stream, %{"/Subtype" => {:name, "Image"}}, _}} =
               Quire.Pdf.get_object(doc, {img_num, 0})
    end

    test "rejects out-of-bounds page indices" do
      pdf = normalized_fixture("simple_text.pdf")
      png = File.read!(@png_path)

      assert {:error, :page_out_of_bounds} = SignatureFlatten.place(pdf, 99, [0, 0, 10, 10], png)
    end

    test "rejects degenerate rects" do
      pdf = normalized_fixture("simple_text.pdf")
      png = File.read!(@png_path)

      assert {:error, :bad_rect} = SignatureFlatten.place(pdf, 0, [10, 10, 5, 5], png)
      assert {:error, :bad_rect} = SignatureFlatten.place(pdf, 0, [10, 10], png)
      assert {:error, :bad_rect} = SignatureFlatten.place(pdf, 0, ["a", 1, 2, 3], png)
    end

    test "rejects non-PNG payloads" do
      pdf = normalized_fixture("simple_text.pdf")

      assert {:error, {:image, _}} = SignatureFlatten.place(pdf, 0, [0, 0, 10, 10], "not a png")
    end
  end

  defp resource_map(doc, page) do
    case Map.get(page, "/Resources") do
      {:ref, rnum, rgen} -> Quire.Pdf.get_object(doc, {rnum, rgen})
      resources when is_map(resources) -> {:ok, resources}
    end
  end
end
