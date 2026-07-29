defmodule Quire.StorageCase do
  @moduledoc """
  Shared helpers for every `Quire.Storage` adapter's test suite.

  Each adapter's test file sets up a temporary storage root and overrides
  the active adapter in its own `setup` block.
  """

  @doc """
  Creates and returns the path to a temporary directory for storage tests.
  The caller must clean it up via `on_exit`.
  """
  def storage_tmp_root! do
    Path.join(System.tmp_dir!(), "quire_storage_test_#{:rand.uniform(1_000_000)}")
  end

  @doc """
  Overrides `:storage_adapter` to `adapter_mod` and returns a zero-arity
  function that restores the previous value.  The caller passes this to
  `on_exit/1`.
  """
  def adapter_setup(adapter_mod) do
    current = Application.fetch_env!(:quire, :storage_adapter)
    Application.put_env(:quire, :storage_adapter, adapter_mod)
    fn -> Application.put_env(:quire, :storage_adapter, current) end
  end

  @doc """
  Returns put opts for the given adapter.
  """
  def put_opts(Quire.Storage.Web, _data), do: [name: "test.bin"]
  def put_opts(Quire.Storage.Web.Filesystem, _data), do: [name: "test.bin"]

  def put_opts(Quire.Storage.Local, _data) do
    tmp_root = Application.get_env(:quire, :data_dir) || System.tmp_dir!()
    path = Path.join(tmp_root, "local_test_#{:rand.uniform(1_000_000)}.bin")
    [path: path, name: "test.bin"]
  end

  def put_opts(_adapter, _data), do: [name: "test.bin"]
end
