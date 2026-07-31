defmodule Quire.PdfATest do
  use ExUnit.Case, async: true

  alias Quire.PdfA

  @fixtures Path.expand("../fixtures/pdfs", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp catalog(bytes) do
    {:ok, q} = Quire.Pdf.open(bytes)
    {:ok, catalog} = Quire.Pdf.get_object(q, 1)
    catalog
  end

  describe "convert/2 — the five steps" do
    test "injects an ICC OutputIntent into the catalog" do
      assert {:ok, out, _report} = PdfA.convert(fixture("simple_text.pdf"))
      catalog = catalog(out)

      assert [intent] = Map.get(catalog, "/OutputIntents")
      assert intent["/S"] == {:name, "GTS_PDFA1"}
      assert {:ref, _, _} = intent["/DestOutputProfile"]

      # the profile object exists and holds the ICC bytes
      {:ok, q} = Quire.Pdf.open(out)
      {:ref, icc_id, _} = intent["/DestOutputProfile"]
      assert {:ok, {:stream, _dict, icc}} = Quire.Pdf.get_object(q, {icc_id, 0})
      assert byte_size(icc) > 100
      # ICC magic "acsp" at offset 36
      assert binary_part(icc, 36, 4) == "acsp"
    end

    test "writes XMP PDF/A-2b metadata into a /Metadata stream" do
      assert {:ok, out, _report} = PdfA.convert(fixture("simple_text.pdf"))
      catalog = catalog(out)
      assert {:ref, meta_id, _} = catalog["/Metadata"]

      {:ok, q} = Quire.Pdf.open(out)
      assert {:ok, {:stream, dict, xmp}} = Quire.Pdf.get_object(q, {meta_id, 0})
      assert dict["/Subtype"] == {:name, "XML"}
      assert xmp =~ "<pdfaid:part>2</pdfaid:part>"
      assert xmp =~ "<pdfaid:conformance>B</pdfaid:conformance>"
    end

    test "sets /MarkInfo /Marked true" do
      assert {:ok, out, _report} = PdfA.convert(fixture("simple_text.pdf"))
      assert catalog(out)["/MarkInfo"]["/Marked"] == true
    end

    test "removes forbidden features (JS / actions) and reports them" do
      assert {:ok, out, report} = PdfA.convert(fixture("simple_text.pdf"))
      catalog = catalog(out)
      refute Map.has_key?(catalog, "/JavaScript")
      refute Map.has_key?(catalog, "/AA")
      refute Map.has_key?(catalog, "/OpenAction")

      forbidden = Enum.find(report.checks, &(&1.name == "Forbidden-feature removal"))
      assert forbidden.status == :pass
    end

    test "reports the font-embedding check as not_verified" do
      assert {:ok, _out, report} = PdfA.convert(fixture("simple_text.pdf"))

      fonts = Enum.find(report.checks, &(&1.name == "Font embedding"))
      assert fonts.status == :not_verified
      assert fonts.detail =~ "could not be verified"
    end
  end

  describe "conformance report" do
    test "is returned on success and lists every check" do
      assert {:ok, _out, report} = PdfA.convert(fixture("simple_text.pdf"))
      assert report.level == "2b"
      assert report.best_effort == true
      assert length(report.checks) == 5
      assert Enum.all?(report.checks, &(&1.status in [:pass, :fail, :not_verified]))
    end

    test "validate/1 reports failures and not-verified checks for a plain doc" do
      assert {:ok, result} = PdfA.validate(fixture("simple_text.pdf"))
      refute result.conformant

      # every check is listed explicitly
      assert Enum.any?(result.checks, &(&1.status == :not_verified))
      assert Enum.any?(result.checks, &(&1.status == :fail))
    end

    test "pdf_a_2b.pdf round-trips without regressing conformance" do
      before = PdfA.validate(fixture("pdf_a_2b.pdf")) |> elem(1)

      assert {:ok, out, _report} = PdfA.convert(fixture("pdf_a_2b.pdf"))
      after_result = PdfA.validate(out) |> elem(1)

      # every check that passed before still passes
      Enum.each(before.checks, fn %{name: name, status: status} ->
        if status == :pass do
          check = Enum.find(after_result.checks, &(&1.name == name))
          assert check.status == :pass, "regressed: #{name}"
        end
      end)
    end

    test "the converted output is a valid PDF" do
      assert {:ok, out, _report} = PdfA.convert(fixture("simple_text.pdf"))
      assert binary_part(out, 0, 5) == "%PDF-"
      assert {:ok, doc} = ExPdfium.open(out)
      assert {:ok, 1} = ExPdfium.page_count(doc)
    end
  end

  describe "best-effort labelling" do
    test "the report and product copy never claim ISO certification" do
      assert {:ok, _out, report} = PdfA.convert(fixture("simple_text.pdf"))
      # report marks best-effort
      assert report.best_effort == true

      # grep-checkable: no claim of certification/compliance anywhere in the
      # product source for PDF/A
      sources =
        Path.wildcard("lib/**/*.ex")
        |> Enum.concat(Path.wildcard("lib/**/*.heex"))

      Enum.each(sources, fn path ->
        content = File.read!(path)

        refute Regex.match?(~r{certified (PDF/A|PDF/A-2b)|ISO 19005|conformant PDF/A}i, content),
               "found an ISO certification claim in #{path}"
      end)
    end
  end
end
