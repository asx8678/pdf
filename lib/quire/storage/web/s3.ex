defmodule Quire.Storage.Web.S3 do
  @moduledoc """
  S3 backend stub (§7.1).

  Raises on every callback with a pointer to §7.1 of the spec.  It exists so
  the seam is visible and so adding S3 later is filling in this module rather
  than discovering that six months of code assumed a real filesystem path.

  The shared `StorageCase` suite for this backend is tagged `@tag :skip`.
  """

  @behaviour Quire.Storage

  @raise_msg """
  Quire.Storage.Web.S3 is a stub — no S3 backend is implemented in v1.
  See plan3.md §7.1 for the filesystem backend (the only built-in adapter),
  or implement the Quire.Storage callbacks here.
  """

  @impl true
  def put(_data, _opts), do: raise(@raise_msg)

  @impl true
  def get(_ref), do: raise(@raise_msg)

  @impl true
  def stream(_ref, _chunk_size), do: raise(@raise_msg)

  @impl true
  def delete(_ref), do: raise(@raise_msg)

  @impl true
  def size(_ref), do: raise(@raise_msg)

  @impl true
  def name(_ref), do: raise(@raise_msg)

  @impl true
  def with_local_path(_ref, _fun), do: raise(@raise_msg)

  @impl true
  def with_local_paths(_refs, _fun), do: raise(@raise_msg)

  @impl true
  def with_scratch_dir(_purpose, _fun), do: raise(@raise_msg)

  @impl true
  def pick_open(_opts), do: raise(@raise_msg)

  @impl true
  def pick_save(_opts), do: raise(@raise_msg)

  @impl true
  def list_dir(_ref), do: raise(@raise_msg)
end
