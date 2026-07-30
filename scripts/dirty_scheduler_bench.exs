#!/usr/bin/env elixir
# Run with: mix run scripts/dirty_scheduler_bench.exs
# Must be run PLUGGED IN (§14.1)

unless Code.ensure_loaded?(Benchee) do
  Mix.install([{:benchee, "~> 1.5"}])
end

# 1. Load the fixture
path = Path.expand("../test/fixtures/pdfs/simple_text.pdf", __DIR__)
{:ok, bytes} = File.read(path)
{:ok, ref} = Quire.Storage.put(bytes, name: "bench.pdf")

# 2. Report system configuration
IO.puts("OTP release: #{:erlang.system_info(:otp_release)}")
IO.puts("Schedulers online: #{:erlang.system_info(:schedulers_online)}")
IO.puts("Dirty CPU schedulers: #{:erlang.system_info(:dirty_cpu_schedulers_online)}")

# 3. Measure baseline :timer.tc latency (no render contention)
{baseline_us, _} = :timer.tc(fn -> :math.sqrt(2) end)
IO.puts("Baseline :timer.tc latency: #{baseline_us} us")

# 4. Spawn a monitor that measures :timer.tc every 100ms DURING the load
parent = self()

_ = spawn(fn ->
  # Record timestamps so we can correlate
  latencies = for _ <- 1..10 do
    :timer.sleep(100)
    {us, _} = :timer.tc(fn -> :math.sqrt(2) end)
    us
  end
  send(parent, {:latencies, latencies})
end)

# 5. Concurrent render benchmark — runs concurrently with the latency monitor
test_fn = fn ->
  for _ <- 1..20 do
    Task.async(fn ->
      {:ok, _png} = Quire.Render.Pdfium.render_page(ref, 0, dpi: 72)
    end)
  end
  |> Task.await_many(:infinity)
end

{render_us, result} = :timer.tc(test_fn)
IO.puts("Number of renders completed: #{length(result)}")
IO.puts("20 concurrent renders took: #{render_us} us")
IO.puts("Average per render: #{Float.round(render_us / 20, 1)} us")

# 6. Collect latency measurements from the monitor
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
