defmodule Quire.Engine do
  @moduledoc """
  Engine registry, boot self-check and telemetry conventions (§7.2).

  Every engine module behind a `Quire.Engine` behaviour emits telemetry
  events through `trace/4` and returns structured errors through
  `Quire.Engine.Error`.
  """

  # A minimal, valid 1‑page PDF (Letter size, 612×792 pt) generated at
  # compile time. Used by the boot smoke test — exercising the full read
  # path (open, page_count, close) rather than a self‑generated document.
  # T‑016 should replace this with a real fixture from the corpus.
  @minimal_pdf_bytes (fn ->
                        hdr = "%PDF-1.4\n"
                        o1 = "1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
                        o2 = "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
                        o3 = "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\n"

                        xref_start = byte_size(hdr <> o1 <> o2 <> o3)

                        xref =
                          "xref\n0 4\n0000000000 65535 f \n" <>
                            String.pad_leading(Integer.to_string(byte_size(hdr)), 10, "0") <>
                            " 00000 n \n" <>
                            String.pad_leading(Integer.to_string(byte_size(hdr <> o1)), 10, "0") <>
                            " 00000 n \n" <>
                            String.pad_leading(
                              Integer.to_string(byte_size(hdr <> o1 <> o2)),
                              10,
                              "0"
                            ) <>
                            " 00000 n \n"

                        trailer = "trailer<</Size 4/Root 1 0 R>>\n"
                        startxref_str = "startxref\n#{xref_start}\n"
                        eof = "%%EOF\n"
                        hdr <> o1 <> o2 <> o3 <> xref <> trailer <> startxref_str <> eof
                      end).()

  # A tiny 2×1 white PNG used as an OCR‑preprocess smoke‑test fixture.
  @smoke_png <<
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x02,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x02,
    0x00,
    0x00,
    0x00,
    0x77,
    0x90,
    0xEE,
    0x89,
    0x00,
    0x00,
    0x00,
    0x10,
    0x49,
    0x44,
    0x41,
    0x54,
    0x08,
    0xD7,
    0x63,
    0x60,
    0x60,
    0x60,
    0x00,
    0x00,
    0x00,
    0x04,
    0x00,
    0x01,
    0x27,
    0x34,
    0x27,
    0xE8,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82
  >>

  @registered_engines [
    {"rasterisation & text extraction", Quire.Render},
    {"OCR / image-to-text", Quire.Ocr.Engine},
    {"office document writing", Quire.Office.Writer},
    {"PAdES signing / validation", Quire.Pades},
    {"document encryption", Quire.SecurityHandler},
    {"PDF/A conversion", Quire.PdfA},
    {"content-stream composition", Quire.Compose},
    {"HTML/URL to PDF rendering", ChromicPDF}
  ]

  @nif_engines [
    {"PDF object model (lopdf Rustler NIF)", Quire.Pdf}
  ]

  @optional_engines [
    Quire.Ocr.Engine,
    ChromicPDF
  ]

  @doc false
  def registered_engines, do: @registered_engines

  @doc false
  def nif_engines, do: @nif_engines

  @doc false
  def optional_engines, do: @optional_engines

  @doc """
  All engines known to the registry (behaviour + NIF).
  """
  def all_engines, do: @registered_engines ++ @nif_engines

  @doc """
  Runs the boot self-check (§7.2).

  Loads each NIF, calls its version/info function, runs a 1‑page PDF and
  a 1‑line PNG through Render and OCR preprocessing end‑to‑end, and
  resolves the Chromium executable from config.

  Returns a map:

    * `:engines` — per‑module status with state, version and detail
    * `:smoke_tests` — `:render` and `:ocr_preprocess` results
    * `:system` — component versions available at check time
  """
  def check do
    engines =
      all_engines()
      |> Enum.reduce(%{}, fn {_desc, mod}, acc ->
        Map.put(acc, mod, check_engine(mod))
      end)

    smoke_tests = %{
      render: run_render_smoke(),
      ocr_preprocess: run_ocr_smoke()
    }

    Map.merge(engines, %{
      engines: engines,
      smoke_tests: smoke_tests,
      system: %{
        pdfium: pdfium_version?(),
        vips: vips_version?(),
        tesseract: tesseract_version?(),
        chromium: chromium_version?(),
        elixir: System.version(),
        otp: System.otp_release(),
        rust: rust_version()
      }
    })
  end

  defp check_engine(mod) do
    try do
      # Ensure the module is loaded before checking exports.
      # function_exported? only checks the currently loaded module; it does
      # NOT trigger lazy-loading of an un-compiled .beam.
      Code.ensure_loaded!(mod)

      if function_exported?(mod, :check, 0) do
        case mod.check() do
          :ok -> %{state: :ok, version: engine_version(mod)}
          {:error, reason} -> %{state: :unavailable, detail: reason}
          _ -> %{state: :unavailable, detail: "unknown check/0 return"}
        end
      else
        # No dedicated check/0 — try loading the module as a basic proof
        if function_exported?(mod, :versions, 0) do
          _ = mod.versions()
          %{state: :ok, version: engine_version(mod)}
        else
          %{state: :unavailable, detail: "no check/0 or versions/0"}
        end
      end
    rescue
      e -> %{state: :unavailable, detail: Exception.message(e)}
    catch
      :exit, reason -> %{state: :unavailable, detail: "exit: #{inspect(reason)}"}
    end
  end

  defp engine_version(mod) do
    Code.ensure_loaded!(mod)

    if function_exported?(mod, :versions, 0) do
      case mod.versions() do
        v when is_map(v) -> inspect(v, limit: :infinity)
        v -> inspect(v)
      end
    else
      Application.spec(mod, :vsn) |> to_string()
    end
  rescue
    _ -> "unknown"
  end

  # ── Smoke tests ──────────────────────────────────────────────────────────

  defp run_render_smoke do
    case ExPdfium.open_blob(@minimal_pdf_bytes) do
      {:ok, doc} ->
        case ExPdfium.page_count(doc) do
          {:ok, count} when count == 1 ->
            ExPdfium.close(doc)
            :ok

          other ->
            ExPdfium.close(doc)
            {:error, "page_count: #{inspect(other)}"}
        end

      {:error, reason} ->
        {:error, "open_blob: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp run_ocr_smoke do
    with {:ok, img} <- Vix.Vips.Image.new_from_buffer(@smoke_png),
         {:ok, _gray} <- Vix.Vips.Operation.colourspace(img, :VIPS_INTERPRETATION_B_W),
         {:ok, _png} <- Vix.Vips.Image.write_to_buffer(img, ".png") do
      :ok
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Component version helpers ────────────────────────────────────────────

  defp pdfium_version? do
    case ExPdfium.pdfium_version() do
      v when is_binary(v) -> v
      {:error, :pdfium_init_failed} -> "unavailable"
    end
  rescue
    _ -> "unavailable"
  end

  defp vips_version? do
    Vix.Vips.version()
  rescue
    _ -> "unavailable"
  end

  defp tesseract_version? do
    Image.OCR.tesseract_version()
  rescue
    _ -> "unavailable"
  end

  defp chromium_version? do
    case Application.get_env(:chromic_pdf, :chrome_executable) do
      nil ->
        case System.get_env("CHROME_EXECUTABLE") do
          nil -> "not configured"
          path -> check_chromium_binary(path)
        end

      path when is_binary(path) ->
        check_chromium_binary(path)
    end
  end

  defp check_chromium_binary(path) do
    if File.exists?(path) do
      version =
        try do
          {output, 0} = System.cmd(path, ["--version"], stderr_to_stdout: true)
          String.trim(output)
        rescue
          _ -> path
        catch
          :exit, _ -> path
        end

      version
    else
      "not found at #{path}"
    end
  end

  @doc """
  Returns component version information for every installed engine and
  system component. Surfaces in Settings → About.

  Collects PDFium, Tesseract, libvips, Chromium, OTP/Elixir, Rust and
  Postgres versions.
  """
  def versions do
    %{
      engines: version_engines(),
      system: %{
        pdfium: ExPdfium.pdfium_version(),
        vips: Vix.Vips.version(),
        tesseract: tesseract_version?(),
        chromium: chromium_version?(),
        elixir: System.version(),
        otp: System.otp_release(),
        rust: rust_version(),
        postgres: pg_version()
      }
    }
  rescue
    _ -> %{engines: %{}, system: %{error: "version collection failed"}}
  end

  defp version_engines do
    all_engines()
    |> Enum.flat_map(fn {_desc, mod} ->
      if function_exported?(mod, :versions, 0) do
        case mod.versions() do
          v when is_map(v) -> [{mod, v}]
          v -> [{mod, %{version: v}}]
        end
      else
        [{mod, %{version: Application.spec(mod, :vsn) |> to_string()}}]
      end
    end)
    |> Map.new()
  rescue
    _ -> %{}
  end

  defp rust_version do
    case System.cmd("rustc", ["--version"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp pg_version do
    case System.cmd("psql", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      _ ->
        "unknown"
    end
  rescue
    _ -> "unknown"
  end

  @doc """
  Prints the boot self‑check table to stdout.
  """
  def print_boot_table do
    result = check()

    IO.puts("")
    IO.puts("╔══════════════════════════════════════════════════════════╗")
    IO.puts("║            Quire Engine Self-Check (§7.2)              ║")
    IO.puts("╚══════════════════════════════════════════════════════════╝")

    IO.puts("")
    IO.puts("── Engines ────────────────────────────────────────────────")

    for {mod, status} <- result.engines do
      state_icon = state_icon(status.state)
      version = Map.get(status, :version, "")
      detail = Map.get(status, :detail, "")

      IO.puts("  #{state_icon} #{inspect(mod)}")

      if version != "" do
        IO.puts("       version: #{version}")
      end

      if detail != "" and status.state != :ok do
        IO.puts("       detail:  #{detail}")
      end
    end

    IO.puts("")
    IO.puts("── Smoke tests ─────────────────────────────────────────────")

    for {name, state} <- result.smoke_tests do
      state_icon =
        case state do
          :ok -> "✓"
          _ -> "✗"
        end

      IO.puts("  #{state_icon} #{name}")

      case state do
        :ok -> :ok
        {:error, detail} -> IO.puts("       #{detail}")
        _ -> IO.puts("       #{inspect(state)}")
      end
    end

    IO.puts("")
    IO.puts("── System components ───────────────────────────────────────")

    for {name, version} <- result.system do
      IO.puts("  #{name}: #{version}")
    end

    IO.puts("")
  end

  defp state_icon(:ok), do: "✓"
  defp state_icon(:degraded), do: "⚠"
  defp state_icon(:unavailable), do: "✗"
  defp state_icon(_), do: "?"

  @doc """
  Wraps an engine call with telemetry events and structured error handling.

  Emits `[:quire, :engine, :start]` before the call, `[:quire, :engine, :stop]`
  on success and `[:quire, :engine, :exception]` on failure.

  Returns `{:ok, result}` on success or `{:error, %Quire.Engine.Error{}}` on failure.

  ## Examples

      Quire.Engine.trace(Quire.Render, :page_count, [ref], fn ->
        Render.Pdfium.page_count(ref)
      end)
  """
  def trace(engine, operation, args, fun)
      when is_atom(engine) and is_atom(operation) and is_list(args) and is_function(fun, 0) do
    metadata = %{engine: engine, operation: operation, args: args}
    start = System.monotonic_time()

    :telemetry.execute([:quire, :engine, :start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()

      duration = System.monotonic_time() - start
      :telemetry.execute([:quire, :engine, :stop], %{duration: duration}, metadata)

      case result do
        {:ok, _} -> result
        {:error, _} -> result
        _ -> {:ok, result}
      end
    rescue
      e ->
        duration = System.monotonic_time() - start

        :telemetry.execute(
          [:quire, :engine, :exception],
          %{duration: duration},
          Map.put(metadata, :error, e)
        )

        {:error,
         %Quire.Engine.Error{
           engine: engine,
           operation: operation,
           code: error_code(e),
           message: user_message(e),
           detail: Exception.message(e)
         }}
    end
  end

  # Erlang error-class mapping: `:function_clause` becomes `%FunctionClauseError{}`,
  # general Erlang errors become `%ErlangError{}`. Neither is a raw NIF atom.
  defp error_code(%ArgumentError{}), do: :invalid_argument
  defp error_code(%RuntimeError{}), do: :runtime
  defp error_code(%FunctionClauseError{}), do: :function_clause
  defp error_code(%ErlangError{}), do: :nif
  defp error_code(_), do: :unknown

  defp user_message(e) do
    cond do
      is_struct(e, ErlangError) -> "A native operation failed. Please try again."
      true -> Exception.message(e)
    end
  end

  @doc """
  Returns true when every **mandatory** engine is `:ok` and every smoke test
  passes.  Optional engines (`Quire.Ocr.Engine`, etc.) may be `:unavailable`
  or `:degraded` without failing the check.

  Used by `mise run doctor` to determine the exit code.
  """
  def healthy? do
    result = check()

    mandatory_engines_ok? =
      result.engines
      |> Enum.reject(fn {mod, _status} -> mod in @optional_engines end)
      |> Enum.all?(fn {_mod, status} -> status.state == :ok end)

    smoke_ok? =
      Enum.all?(result.smoke_tests, fn {_name, state} -> state == :ok end)

    mandatory_engines_ok? && smoke_ok?
  end

  @doc """
  Classifies an engine status into user-facing severity (§7.2).

  ## States

    * `:ok` — Engine loaded, self-test passed
    * `:degraded` — Engine loaded, self-test flaky or version drifted
    * `:unavailable` — Engine failed to load or feature disabled

  Returns `:ok`, `:degraded`, or `:unavailable`.
  """
  def classify(status)

  def classify(:ok), do: :ok
  def classify(:degraded), do: :degraded
  def classify(:unavailable), do: :unavailable
  def classify(_), do: :unavailable
end
