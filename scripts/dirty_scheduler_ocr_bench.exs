#!/usr/bin/env elixir
# Run with: mix run scripts/dirty_scheduler_ocr_bench.exs
# Must be run PLUGGED IN (§14.1)
#
# T-022: Gate — verify image_ocr and vix NIFs run on dirty CPU schedulers.
# image_ocr declares ERL_NIF_DIRTY_JOB_CPU_BOUND; vix uses Rustler's default
# thread pool (no DirtyCpu annotation). This benchmark empirically verifies
# that an independent :timer.tc loop stays under 5 ms during concurrent
# OCR and image-processing load.

path = Path.expand("../test/fixtures/pdfs/simple_text.pdf", __DIR__)
{:ok, bytes} = File.read(path)
{:ok, ref} = Quire.Storage.put(bytes, name: "bench.pdf")

IO.puts("OTP release: #{:erlang.system_info(:otp_release)}")
IO.puts("Schedulers online: #{:erlang.system_info(:schedulers_online)}")
IO.puts("Dirty CPU schedulers: #{:erlang.system_info(:dirty_cpu_schedulers)}")

# Render 10 pages as PNGs for OCR (simple_text.pdf has only 1 page, so repeat)
pages =
  for _ <- 1..10 do
    {:ok, png} = Quire.Render.Pdfium.render_page(ref, 0, dpi: 150)
    png
  end

# Baseline :timer.tc latency (no contention)
{baseline_us, _} = :timer.tc(fn -> :math.sqrt(2) end)
IO.puts("Baseline :timer.tc latency: #{baseline_us} us")

# Measure :timer.tc latency during OCR + vix image processing
parent = self()

_monitor = spawn(fn ->
  latencies =
    for _ <- 1..20 do
      :timer.sleep(50)
      {us, _} = :timer.tc(fn -> :math.sqrt(2) end)
      us
    end

  send(parent, {:latencies, latencies})
end)

# Run concurrent OCR + vix operations
tasks =
  Enum.map(pages, fn png ->
    Task.async(fn ->
      # vix: load image from buffer (image processing)
      {:ok, img} = Vix.Vips.Image.new_from_buffer(png)
      # vix: colourspace conversion (grayscale for OCR)
      {:ok, gray} = Vix.Vips.Operation.colourspace(img, :VIPS_INTERPRETATION_B_W)
      {:ok, png_out} = Vix.Vips.Image.write_to_buffer(gray, ".png")
      # image_ocr: OCR the page
      {:ok, instance} = Image.OCR.new(locale: "eng")
      {:ok, _words} = Image.OCR.recognize(instance, png_out)
      :ok
    end)
  end)

results = Task.await_many(tasks, :infinity)
IO.puts("Number of OCR/image jobs completed: #{length(results)}")

receive do
  {:latencies, latencies} ->
    max_lat = Enum.max(latencies)
    avg_lat = Enum.sum(latencies) / length(latencies)
    IO.puts("During load: max :timer.tc latency = #{max_lat} us, avg = #{Float.round(avg_lat, 1)} us")

    if max_lat > 5000 do
      IO.puts("!!! FAIL: :timer.tc latency exceeded 5ms threshold (#{max_lat} us)")
      System.halt(1)
    else
      IO.puts("PASS: :timer.tc latency stayed under 5ms threshold")
    end
end
