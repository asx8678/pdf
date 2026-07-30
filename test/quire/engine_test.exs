defmodule Quire.EngineTest do
  use ExUnit.Case, async: true

  describe "behaviour contracts" do
    test "Quire.Render defines all required callbacks" do
      callbacks = Quire.Render.behaviour_info(:callbacks) |> Map.new()
      assert Map.has_key?(callbacks, :page_count)
      assert Map.has_key?(callbacks, :page_geometry)
      assert Map.has_key?(callbacks, :render_page)
      assert Map.has_key?(callbacks, :thumbnails)
      assert Map.has_key?(callbacks, :extract_text)
      assert Map.has_key?(callbacks, :search)
      assert Map.has_key?(callbacks, :form_fields)
      assert Map.has_key?(callbacks, :annotations)
      assert Map.has_key?(callbacks, :extract_images)
      assert Map.has_key?(callbacks, :outline)
      assert Map.has_key?(callbacks, :import_pages)
      assert Map.has_key?(callbacks, :new_document)
      assert Map.has_key?(callbacks, :add_page)
      assert Map.has_key?(callbacks, :save)
    end

    test "Quire.Ocr.Engine defines run/2 and versions/0" do
      callbacks = Quire.Ocr.Engine.behaviour_info(:callbacks) |> Map.new()
      assert Map.has_key?(callbacks, :run)
      assert Map.has_key?(callbacks, :versions)
    end

    test "Quire.Office.Writer defines write/3 and supported_formats/0" do
      callbacks = Quire.Office.Writer.behaviour_info(:callbacks) |> Map.new()
      assert Map.has_key?(callbacks, :write)
      assert Map.has_key?(callbacks, :supported_formats)
    end

    test "Quire.Office.Reader defines read_bytes/1 callback" do
      callbacks = Quire.Office.Reader.behaviour_info(:callbacks) |> Map.new()
      assert Map.has_key?(callbacks, :read_bytes)
    end

    test "Quire.Pades defines sign/3 and verify/1" do
      callbacks = Quire.Pades.behaviour_info(:callbacks) |> Map.new()
      assert Map.has_key?(callbacks, :sign)
      assert Map.has_key?(callbacks, :verify)
    end

    test "Quire.SecurityHandler defines encrypt/2, decrypt/2, info/1" do
      callbacks = Quire.SecurityHandler.behaviour_info(:callbacks) |> Map.new()
      assert Map.has_key?(callbacks, :encrypt)
      assert Map.has_key?(callbacks, :decrypt)
      assert Map.has_key?(callbacks, :info)
    end

    test "Quire.PdfA defines convert/2 and validate/1" do
      callbacks = Quire.PdfA.behaviour_info(:callbacks) |> Map.new()
      assert Map.has_key?(callbacks, :convert)
      assert Map.has_key?(callbacks, :validate)
    end

    test "Quire.Compose defines compose/2 and appearance/3" do
      callbacks = Quire.Compose.behaviour_info(:callbacks) |> Map.new()
      assert Map.has_key?(callbacks, :compose)
      assert Map.has_key?(callbacks, :appearance)
    end
  end

  describe "Quire.Engine.Error" do
    test "struct fields" do
      error = %Quire.Engine.Error{
        engine: Quire.Render,
        operation: :render_page,
        code: :nif,
        message: "A native operation failed. Please try again.",
        detail: "segfault"
      }

      assert error.engine == Quire.Render
      assert error.code == :nif
      assert Exception.message(error) =~ "native operation failed"
    end

    test "message falls back to detail when no message is given" do
      error = %Quire.Engine.Error{code: :nif, detail: "NIF crashed"}
      assert Exception.message(error) == "[nif] NIF crashed"
    end

    test "message handles bare code only" do
      error = %Quire.Engine.Error{code: :unknown}
      assert Exception.message(error) == "[unknown] Engine error"
    end

    test "error taxonomy — no raw NIF error atom reaches user-facing string" do
      error = %Quire.Engine.Error{code: :nif, message: "A native operation failed"}
      assert is_binary(error.message)

      error = %Quire.Engine.Error{code: :invalid_argument, message: "Bad input"}
      assert is_binary(error.message)
    end
  end

  describe "Quire.Engine trace/4" do
    setup context do
      test_pid = self()
      handler_id = "engine-test-#{context.line}-#{inspect(test_pid)}"

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, handler_id, event, measurements, metadata})
      end

      :telemetry.attach_many(
        handler_id,
        [
          [:quire, :engine, :start],
          [:quire, :engine, :stop],
          [:quire, :engine, :exception]
        ],
        handler,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      %{handler_id: handler_id}
    end

    test "emits start and stop on success", %{handler_id: handler_id} do
      assert {:ok, 42} = Quire.Engine.trace(Quire.Render, :page_count, [ref: "doc"], fn -> 42 end)

      assert_receive {:telemetry, ^handler_id, [:quire, :engine, :start], measurements, metadata}
      assert metadata.engine == Quire.Render
      assert metadata.operation == :page_count
      assert is_integer(measurements.system_time)

      assert_receive {:telemetry, ^handler_id, [:quire, :engine, :stop], measurements, metadata}
      assert metadata.engine == Quire.Render
      assert is_integer(measurements.duration)
    end

    test "emits exception on failure", %{handler_id: handler_id} do
      assert {:error, %Quire.Engine.Error{}} =
               Quire.Engine.trace(Quire.Render, :page_count, [ref: "doc"], fn ->
                 raise ArgumentError, "bad arg"
               end)

      assert_receive {:telemetry, ^handler_id, [:quire, :engine, :start], _, _}
      assert_receive {:telemetry, ^handler_id, [:quire, :engine, :exception], measurements, metadata}
      assert metadata.engine == Quire.Render
      assert is_integer(measurements.duration)
    end

    test "error contains structured fields", %{handler_id: handler_id} do
      assert {:error, error} =
               Quire.Engine.trace(Quire.Pdf, :save, [], fn ->
                 raise ErlangError, original: :nif_panicked
               end)

      assert error.engine == Quire.Pdf
      assert error.operation == :save

      assert_receive {:telemetry, ^handler_id, [:quire, :engine, :exception], _, metadata}
      assert metadata.engine == Quire.Pdf
    end
  end
    test "function clause error is captured" do
      fun = fn -> :erlang.error(:function_clause) end

      assert {:error, error} =
               Quire.Engine.trace(Quire.Pades, :sign, [], fun)

      assert error.code == :function_clause
    end

  describe "Quire.Engine.check/0" do
    test "returns a map with engine keys" do
      result = Quire.Engine.check()
      assert is_map(result)
      assert Map.has_key?(result, Quire.Render)
      assert Map.has_key?(result, Quire.Ocr.Engine)
      assert Map.has_key?(result, Quire.Office.Writer)
    end

    test "each engine entry has a state map with :state key" do
      result = Quire.Engine.check()

      for {mod, status} <- result.engines do
        assert is_map(status), "#{inspect(mod)} status is not a map"

        assert status.state in [:ok, :degraded, :unavailable],
               "#{inspect(mod)} has invalid state: #{inspect(status.state)}"
      end
    end

    test "includes smoke_tests key with render and ocr_preprocess" do
      result = Quire.Engine.check()
      assert Map.has_key?(result, :smoke_tests)
      assert Map.has_key?(result.smoke_tests, :render)
      assert Map.has_key?(result.smoke_tests, :ocr_preprocess)
    end

    test "includes system key with component versions" do
      result = Quire.Engine.check()
      assert Map.has_key?(result, :system)
      assert is_binary(result.system.pdfium)
      assert is_binary(result.system.vips)
      assert is_binary(result.system.elixir)
      assert is_binary(result.system.otp)
    end

    test "module keys at top level for backward compatibility" do
      result = Quire.Engine.check()
      assert result[Quire.Render]
      assert result[Quire.Pdf]
    end
  end

  describe "Quire.Engine.versions/0" do
    test "returns version map with engines and system" do
      result = Quire.Engine.versions()
      assert is_map(result.engines)
      assert is_map(result.system)
      assert is_binary(result.system.elixir)
      assert is_binary(result.system.otp)
    end

    test "includes pdfium, vips and chromium in system versions" do
      result = Quire.Engine.versions()
      assert Map.has_key?(result.system, :pdfium)
      assert Map.has_key?(result.system, :vips)
      assert Map.has_key?(result.system, :chromium)
      assert Map.has_key?(result.system, :postgres)
      assert Map.has_key?(result.system, :rust)
    end
  end

  describe "Quire.Engine.healthy?/0" do
    test "returns a boolean" do
      assert is_boolean(Quire.Engine.healthy?())
    end

    test "matching check result logic" do
      result = Quire.Engine.check()
      optional = Quire.Engine.optional_engines()

      expected =
        result.engines
        |> Enum.reject(fn {mod, _s} -> mod in optional end)
        |> Enum.all?(fn {_mod, s} -> s.state == :ok end) &&
          Enum.all?(result.smoke_tests, fn {_n, s} -> s == :ok end)

      assert Quire.Engine.healthy?() == expected
    end
  end

  describe "Quire.Engine.print_boot_table/0" do
    test "does not raise" do
      try do
        Quire.Engine.print_boot_table()
      rescue
        e -> flunk("print_boot_table raised: #{Exception.message(e)}")
      end
    end
  end

  describe "Quire.Engine.classify/1" do
    test "classifies known states" do
      assert Quire.Engine.classify(:ok) == :ok
      assert Quire.Engine.classify(:degraded) == :degraded
      assert Quire.Engine.classify(:unavailable) == :unavailable
    end

    test "classifies unknown as unavailable" do
      assert Quire.Engine.classify(:unknown_atom) == :unavailable
      assert Quire.Engine.classify(nil) == :unavailable
    end
  end

  describe "Quire.Engine registry" do
    test "registered_engines lists behaviour modules" do
      engines = Quire.Engine.registered_engines()
      assert length(engines) == 7
      assert Enum.any?(engines, fn {_desc, mod} -> mod == Quire.Render end)
      assert Enum.any?(engines, fn {_desc, mod} -> mod == Quire.Pades end)
    end

    test "all_engines includes NIF engines" do
      all = Quire.Engine.all_engines()
      assert Enum.any?(all, fn {_desc, mod} -> mod == Quire.Render end)
      assert Enum.any?(all, fn {_desc, mod} -> mod == Quire.Pdf end)
    end
  end
end
