defmodule Quire.Storage.Web do
  @moduledoc """
  Web-application storage adapter (§7.1).

  Implements `Quire.Storage` by dispatching to a backend chosen by
  `config :quire, :storage_backend`.  The only backend built in v1 is
  `Quire.Storage.Web.Filesystem`; a raising `Quire.Storage.Web.S3` stub
  keeps the seam honest.
  """

  @behaviour Quire.Storage

  alias Quire.Storage.Ref

  @doc false
  def backend do
    Application.fetch_env!(:quire, :storage_backend)
  end

  @impl true
  def put(data, opts \\ []) do
    backend().put(data, opts)
  end

  @impl true
  def get(%Ref{} = ref) do
    backend().get(ref)
  end

  @impl true
  def stream(%Ref{} = ref, chunk_size \\ 65_536) do
    backend().stream(ref, chunk_size)
  end

  @impl true
  def delete(%Ref{} = ref) do
    backend().delete(ref)
  end

  @impl true
  def size(%Ref{} = ref) do
    backend().size(ref)
  end

  @impl true
  def name(%Ref{} = ref) do
    backend().name(ref)
  end

  @impl true
  def with_local_path(%Ref{} = ref, fun) when is_function(fun, 1) do
    backend().with_local_path(ref, fun)
  end

  @impl true
  def with_local_paths(refs, fun) when is_list(refs) and is_function(fun, 1) do
    backend().with_local_paths(refs, fun)
  end

  @impl true
  def with_scratch_dir(purpose, fun) when is_binary(purpose) and is_function(fun, 1) do
    backend().with_scratch_dir(purpose, fun)
  end

  @impl true
  def pick_open(opts \\ []) do
    backend().pick_open(opts)
  end

  @impl true
  def pick_save(opts \\ []) do
    backend().pick_save(opts)
  end

  @impl true
  def list_dir(%Ref{} = ref) do
    backend().list_dir(ref)
  end
end
