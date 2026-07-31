defmodule Quire.Gate4MemoryBudgetTest do
  # Gate 4 Item 4 — 50 MB memory budget (§14.1).
  #
  # A 50 MB document (`test/fixtures/pdfs/50mb_images.pdf` — 250 images at
  # 1000x200 device-gray, ~47 MB on disk) must convert while staying inside
  # the §14.1 budget:
  #
  #   "BEAM memory per open document | < 50 MB in Elixir binaries (stream;
  #   never hold a whole PDF in a process)"
  #
  # The pipeline under test is the PDF-based Compress path that avoids
  # Chromium entirely (the fixture is already a PDF, so HTML→Chromium would
  # be a pointless detour):
  #
  #   Quire.Pdf.open_file/1        — parses on disk inside the NIF; the
  #                                  document bytes live in the Rust heap,
  #                                  never in a BEAM binary.
  #   Quire.Compress.compress_handle/2
  #                                — recompresses image XObjects one page at
  #                                  a time, fetching each stream payload as
  #                                  a transient BEAM binary that is dropped
  #                                  before the next page. libvips'
  #                                  operation cache is disabled for the
  #                                  pass so dead image memory is not
  #                                  retained between pages.
  #   Quire.Pdf.save_with/2        — only the compressed output binary is
  #                                  materialised in BEAM.
  #
  # The document reference is deliberately kept alive (assigned in the test
  # process) for the whole measurement, and the BEAM binary allocator is
  # sampled every millisecond during the conversion, so the assertion is
  # against real peak memory attributable to the open document — not a
  # post-hoc total.
  #
  # Serialised (async: false): memory measurements are global to the VM and
  # would be corrupted by concurrent tests.
  use ExUnit.Case, async: false

  alias Quire.Compress
  alias Quire.Pdf

  @fixture "test/fixtures/pdfs/50mb_images.pdf"
  # §14.1 line 2610: < 50 MB in Elixir binaries per open document
  @budget_bytes 50 * 1024 * 1024

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Samples :erlang.memory(:binary) every millisecond from a linked process
  # until told to stop, returning the peak observed.
  defp sample_peak_binary do
    parent = self()

    sampler =
      spawn_link(fn ->
        peak =
          Enum.reduce_while(Stream.repeatedly(fn -> :erlang.memory(:binary) end), 0, fn bytes,
                                                                                        max ->
            receive do
              :stop -> {:halt, max}
            after
              1 -> {:cont, max(max, bytes)}
            end
          end)

        send(parent, {:peak, peak})
      end)

    # Give the sampler a chance to start sampling before work begins.
    Process.sleep(5)

    on_exit(fn -> Process.exit(sampler, :kill) end)

    fn ->
      send(sampler, :stop)

      receive do
        {:peak, peak} -> peak
      after
        5_000 -> :timeout
      end
    end
  end

  defp gc_all do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    Process.sleep(50)
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    :ok
  end

  defp binary_delta_after_gc(base) do
    gc_all()
    :erlang.memory(:binary) - base
  end

  defp fixture_size do
    File.stat!(@fixture).size
  end

  # ── The document itself fits the fixture corpus ─────────────────────────

  describe "fixture" do
    test "50mb_images.pdf exists and is a ~50 MB document" do
      size = fixture_size()
      assert size >= 40 * 1024 * 1024, "expected a ~50 MB fixture, got #{size} bytes"
      assert size < 60 * 1024 * 1024, "expected a ~50 MB fixture, got #{size} bytes"

      # Sanity: it is a PDF with 250 image pages.
      {:ok, q} = Pdf.open_file(@fixture)
      assert {:ok, 250} = Pdf.page_count(q)
    end
  end

  # ── Streaming open: never materialise the whole PDF in BEAM ─────────────

  describe "open (handle kept alive)" do
    test "opening the 50 MB document adds ~0 BEAM binary memory" do
      gc_all()
      base = :erlang.memory(:binary)

      # The handle stays alive for the whole test — the document lives in the
      # NIF's Rust heap, not in an Elixir binary.
      {:ok, q} = Pdf.open_file(@fixture)
      assert {:ok, 250} = Pdf.page_count(q)

      # Holds the handle in the test process scope until the assertion below.
      retained = binary_delta_after_gc(base)

      # Reading the page tree and a few objects must not load the image
      # streams (the payloads are only materialised per-page by the
      # recompression pass).
      assert retained < 1 * 1024 * 1024,
             "opening the document retained #{div(retained, 1024 * 1024)} MB of BEAM binary memory"

      # Keep the handle referenced so it is not GC'd mid-test.
      _ = q
    end
  end

  # ── Conversion inside the §14.1 budget ──────────────────────────────────

  describe "compress_handle/2 on the 50 MB document" do
    test "converts within the < 50 MB BEAM binary budget and produces valid output" do
      gc_all()
      base = :erlang.memory(:binary)
      stop_sampling = sample_peak_binary()

      # The document reference stays alive for the entire conversion — the
      # budget is per *open document*, so we must not let it be collected.
      {:ok, q} = Pdf.open_file(@fixture)
      assert {:ok, 250} = Pdf.page_count(q)

      assert {:ok, out} = Compress.compress_handle(q, preset: :high)

      peak = stop_sampling.()

      attributable = peak - base

      assert attributable < @budget_bytes,
             "peak BEAM binary memory attributable to the open document was " <>
               "#{div(attributable, 1024 * 1024)} MB — over the §14.1 < 50 MB budget"

      # The output must be a real, smaller, valid PDF.
      assert byte_size(out) < fixture_size(), "compress must reduce the 50 MB document"
      assert binary_part(out, 0, 5) == "%PDF-"
      assert :binary.match(out, "/ObjStm") != :nomatch, "object streams must be used"

      {:ok, reopened} = ExPdfium.open_blob(out)
      assert {:ok, 250} = ExPdfium.page_count(reopened)

      # The handle must remain usable after the streaming pass.
      assert {:ok, out2} = Pdf.save(q)
      assert binary_part(out2, 0, 5) == "%PDF-"

      # Nothing is retained once the output is dropped and the handle is gone.
      _out = out
      _q = q
      retained = binary_delta_after_gc(base)

      assert retained < 1 * 1024 * 1024,
             "conversion retained #{div(retained, 1024 * 1024)} MB after GC"
    end
  end

  describe "compress_file/2 end-to-end on the 50 MB document" do
    test "converts from disk within budget and reopens" do
      gc_all()
      base = :erlang.memory(:binary)
      stop_sampling = sample_peak_binary()

      assert {:ok, out} = Compress.compress_file(@fixture, preset: :high)

      peak = stop_sampling.()

      attributable = peak - base

      assert attributable < @budget_bytes,
             "peak BEAM binary memory was #{div(attributable, 1024 * 1024)} MB — over budget"

      assert byte_size(out) < fixture_size()
      assert binary_part(out, 0, 5) == "%PDF-"

      {:ok, reopened} = ExPdfium.open_blob(out)
      assert {:ok, 250} = ExPdfium.page_count(reopened)
    end
  end

  # ── Unsupported streams are skipped, not fatal ──────────────────────────

  describe "streams the handle path cannot decode" do
    test "a small document without images still converts" do
      # Use the normalised tagged fixture (no raster images at all).
      {:ok, doc} = ExPdfium.open_file("test/fixtures/pdfs/tagged_accessible.pdf")
      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      tmp = Path.join(System.tmp_dir!(), "gate4_tagged_#{System.unique_integer([:positive])}.pdf")
      File.write!(tmp, bytes)

      try do
        {:ok, out} = Compress.compress_file(tmp, preset: :medium)
        assert byte_size(out) > 0
        assert binary_part(out, 0, 5) == "%PDF-"

        {:ok, q} = Pdf.open(out)
        {:ok, catalog} = Pdf.get_object(q, 1)
        assert Map.has_key?(catalog, "/StructTreeRoot"), "accessibility must be preserved"
      after
        File.rm!(tmp)
      end
    end
  end
end
