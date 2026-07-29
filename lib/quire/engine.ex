defmodule Quire.Engine do
  @moduledoc """
  Engine registry, boot self-check skeleton and telemetry conventions (§7.2).

  Every engine module behind a `Quire.Engine` behaviour emits telemetry
  events through `trace/4` and returns structured errors through
  `Quire.Engine.Error`.
  """

  @registered_engines [
    {"rasterisation & text extraction", Quire.Render},
    {"OCR / image-to-text", Quire.Ocr.Engine},
    {"office document writing", Quire.Office.Writer},
    {"PAdES signing / validation", Quire.Pades},
    {"document encryption", Quire.SecurityHandler},
    {"PDF/A conversion", Quire.PdfA},
    {"content-stream composition", Quire.Compose}
  ]

  @nif_engines [
    {"PDF object model (lopdf Rustler NIF)", Quire.Pdf}
  ]

  @doc false
  def registered_engines, do: @registered_engines

  @doc false
  def nif_engines, do: @nif_engines

  @doc """
  All engines known to the registry (behaviour + NIF).
  """
  def all_engines, do: @registered_engines ++ @nif_engines

  @doc """
  Runs the boot self-check.

  Loads each NIF, calls its version function, and runs small fixture
  smoke tests. Returns a map of engine → status.

  Skeleton — full implementation is T-013.
  """
  def check do
    all_engines()
    |> Enum.reduce(%{}, fn {_desc, mod}, acc ->
      status =
        try do
          if function_exported?(mod, :check, 0) do
            case mod.check() do
              :ok -> :ok
              _ -> :unavailable
            end
          else
            {:unavailable, "no check/0 — T-013"}
          end
        rescue
          _ -> :unavailable
        catch
          :exit, _ -> :unavailable
        end

      Map.put(acc, mod, status)
    end)
  end

  @doc """
  Returns component version information.

  Skeleton — captures versions from installed engines and system
  components. Full implementation is T-013.
  """
  def versions do
    %{
      engines: version_engines(),
      system: %{
        elixir: System.version(),
        otp: System.otp_release(),
        rust: rust_version()
      }
    }
  end

  defp version_engines do
    @registered_engines
    |> Enum.flat_map(fn {_desc, mod} ->
      if function_exported?(mod, :versions, 0) do
        [{mod, mod.versions()}]
      else
        []
      end
    end)
    |> Map.new()
  end

  defp rust_version do
    case System.cmd("rustc", ["--version"], stderr: :ignore, into: []) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

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

      {:ok, result}
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
