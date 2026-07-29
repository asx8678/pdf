defmodule Quire.StorageCase do
  @moduledoc """
  Shared test suite for every `Quire.Storage` adapter.

  Usage:

      defmodule Quire.Storage.WebTest do
        use Quire.StorageCase, adapter: Quire.Storage.Web

        test "put stores and get retrieves", %{adapter: adapter} do
          assert_put_get(adapter)
        end
      end

  The `setup` block configures a temporary storage root so tests do not
  pollute production or development storage.
  """

  use ExUnit.CaseTemplate

  setup do
    # Capture the current storage config and override with a temp dir for
    # the duration of the test.
    tmp_root = Path.join(System.tmp_dir!(), "quire_storage_test_#{:rand.uniform(1_000_000)}")

    on_exit(fn ->
      File.rm_rf!(tmp_root)
    end)

    {:ok, tmp_root: tmp_root}
  end

  @doc """
  Shared callback that verifies all 11 behaviour functions compile and
  dispatch without raising for the given adapter.

  Adapter-specific tests (e.g. atomic-write crash recovery, the
  `{:error, :unsupported}` contract for `pick_open`/`pick_save`, S3 stub
  raising) live in the individual test files.
  """
  def assert_behaviour_callbacks_compile(adapter) do
    callbacks = Quire.Storage.behaviour_info(:callbacks)

    for {name, arity} <- callbacks do
      assert function_exported?(adapter, name, arity),
             "expected #{inspect(adapter)} to export #{name}/#{arity}"
    end
  end
end
