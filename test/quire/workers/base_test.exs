defmodule Quire.Workers.BaseTest do
  use ExUnit.Case, async: true

  alias Quire.Workers.Base

  describe "queue configuration" do
    test "queues are configured with literal constants" do
      oban_config = Application.fetch_env!(:quire, Oban)
      queues = Keyword.fetch!(oban_config, :queues)

      assert Keyword.get(queues, :render) == 1,
             "render must be 1 — PDFIUM_LOCK serialises all calls"

      assert Keyword.get(queues, :transform) == 1,
             "transform must be 1 — shares PDFIUM_LOCK with render"

      assert Keyword.get(queues, :convert) == 1
      assert Keyword.get(queues, :ocr) == 1
      assert Keyword.get(queues, :secure) == 2
      assert Keyword.get(queues, :esign) == 2
      assert Keyword.get(queues, :translate) == 2
      assert Keyword.get(queues, :batch) == 1
      assert Keyword.get(queues, :maintenance) == 1
    end

    test "render and transform are explicitly bounded and cannot float up" do
      oban_config = Application.fetch_env!(:quire, Oban)
      queues = Keyword.fetch!(oban_config, :queues)

      render = Keyword.get(queues, :render)
      transform = Keyword.get(queues, :transform)

      assert is_integer(render) and render == 1,
             "render concurrency is a literal constant (1), not derived"

      assert is_integer(transform) and transform == 1,
             "transform concurrency is a literal constant (1), not derived"
    end

    test "Oban plugins are enabled" do
      oban_config = Application.fetch_env!(:quire, Oban)
      plugins = Keyword.fetch!(oban_config, :plugins)

      plugin_modules =
        Enum.map(plugins, fn
          {mod, _opts} -> mod
          mod when is_atom(mod) -> mod
        end)

      assert Oban.Plugins.Pruner in plugin_modules
      assert Oban.Plugins.Lifeline in plugin_modules
      assert Oban.Plugins.Reindexer in plugin_modules
    end
  end

  describe "Base behaviour" do
    test "responds to callback functions" do
      Code.ensure_loaded!(Base)
      assert function_exported?(Base, :report_progress, 3)
      assert function_exported?(Base, :guard_idempotent, 2)
    end
  end
end
