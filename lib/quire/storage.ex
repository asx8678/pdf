defmodule Quire.Storage do
  @moduledoc """
  The storage boundary — `put`, `get`, `stream`, `delete` and lifecycle helpers
  for blobs identified by opaque `t:Quire.Storage.Ref.t/0` refs.

  ## Dispatch

  Every public function in this module looks up the active adapter at **runtime**
  via `Application.fetch_env!(:quire, :storage_adapter)`.  This compile-time
  freedom is deliberate — `defdelegate` would bake the adapter into the release
  and destroy the web-vs-desktop swap that all of §12 depends on.

  Callers see refs and binaries, never filesystem paths.  The only sanctioned
  way to obtain a real path is `with_local_path/2` or `with_local_paths/2`,
  whose lifetime is scoped to the function passed as the second argument.
  """

  alias Quire.Storage.Ref

  # ── Callbacks ───────────────────────────────────────────────────────────

  @doc """
  Stores `data` with optional metadata and returns the resulting ref.
  """
  @callback put(data :: binary(), opts :: keyword()) ::
              {:ok, Ref.t()} | {:error, term()}

  @doc """
  Retrieves the full content of a stored ref.
  """
  @callback get(ref :: Ref.t()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Streams the ref's content in `chunk_size`-byte chunks.
  """
  @callback stream(ref :: Ref.t(), chunk_size :: pos_integer()) :: Enumerable.t()

  @doc """
  Deletes the stored blob identified by `ref`.
  """
  @callback delete(ref :: Ref.t()) :: :ok | {:error, term()}

  @doc """
  Returns the size of the blob in bytes.
  """
  @callback size(ref :: Ref.t()) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Returns the human-facing name associated with `ref`.
  """
  @callback name(ref :: Ref.t()) :: String.t()

  @doc """
  Materialises `ref` to a local filesystem path, invokes `fun` with that path,
  and cleans up afterwards.

  For filesystem-backed adapters this may hand over the real path directly
  (the cheap case).  Callers **must** still treat the path as valid only
  inside `fun` — this is the only sanctioned way to obtain a filesystem path
  (§3.4, §7.1).
  """
  @callback with_local_path(ref :: Ref.t(), fun :: (String.t() -> result)) :: result
            when result: term()

  @doc """
  Like `with_local_path/2` but materialises multiple refs at once.
  """
  @callback with_local_paths(refs :: [Ref.t()], fun :: ([String.t()] -> result)) :: result
            when result: term()

  @doc """
  Creates a scratch directory with the given `purpose` prefix, invokes `fun`
  with the directory path, and removes the directory (even on crash).
  """
  @callback with_scratch_dir(purpose :: String.t(), fun :: (String.t() -> result)) :: result
            when result: term()

  @doc """
  Opens a native file-picker dialog for opening a file.

  Desktop adapters return `{:ok, ref}`.  Web adapters return
  `{:error, :unsupported}`.
  """
  @callback pick_open(opts :: keyword()) :: {:ok, Ref.t()} | {:error, term()}

  @doc """
  Opens a native file-picker dialog for saving a file.

  Desktop adapters return `{:ok, ref}`.  Web adapters return
  `{:error, :unsupported}`.
  """
  @callback pick_save(opts :: keyword()) :: {:ok, Ref.t()} | {:error, term()}

  @doc """
  Lists entries inside a ref that acts as a directory.
  """
  @callback list_dir(ref :: Ref.t()) :: {:ok, [Ref.t()]} | {:error, term()}

  # ── Public API — runtime dispatch ───────────────────────────────────────

  @doc """
  Stores `data` and returns `{:ok, ref}`.
  """
  @spec put(data :: binary(), opts :: keyword()) :: {:ok, Ref.t()} | {:error, term()}
  def put(data, opts \\ []) do
    adapter().put(data, opts)
  end

  @doc """
  Retrieves the full content for `ref`.
  """
  @spec get(ref :: Ref.t()) :: {:ok, binary()} | {:error, term()}
  def get(%Ref{} = ref) do
    adapter().get(ref)
  end

  @doc """
  Streams the content of `ref` in `chunk_size`-byte chunks.

  Returns an enumerable that lazily reads from storage.
  """
  @spec stream(ref :: Ref.t(), chunk_size :: pos_integer()) :: Enumerable.t()
  def stream(%Ref{} = ref, chunk_size \\ 65_536) do
    adapter().stream(ref, chunk_size)
  end

  @doc """
  Deletes the blob identified by `ref`.
  """
  @spec delete(ref :: Ref.t()) :: :ok | {:error, term()}
  def delete(%Ref{} = ref) do
    adapter().delete(ref)
  end

  @doc """
  Returns `{:ok, byte_count}` for `ref`.
  """
  @spec size(ref :: Ref.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def size(%Ref{} = ref) do
    adapter().size(ref)
  end

  @doc """
  Returns the human-facing name for `ref`.
  """
  @spec name(ref :: Ref.t()) :: String.t()
  def name(%Ref{} = ref) do
    adapter().name(ref)
  end

  @doc """
  Materialises `ref` to a local path, calls `fun`, cleans up.

  ## Examples

      Quire.Storage.with_local_path(ref, fn path ->
        File.read!(path)
      end)
  """
  @spec with_local_path(ref :: Ref.t(), fun :: (String.t() -> result)) :: result
        when result: term()
  def with_local_path(%Ref{} = ref, fun) when is_function(fun, 1) do
    adapter().with_local_path(ref, fun)
  end

  @doc """
  Materialises multiple refs to local paths, calls `fun`, cleans up.
  """
  @spec with_local_paths(refs :: [Ref.t()], fun :: ([String.t()] -> result)) :: result
        when result: term()
  def with_local_paths(refs, fun) when is_list(refs) and is_function(fun, 1) do
    adapter().with_local_paths(refs, fun)
  end

  @doc """
  Creates a scratch directory, calls `fun`, removes the directory.

  The directory is named with `purpose` as a prefix so concurrent operations
  do not collide.

  ## Examples

      Quire.Storage.with_scratch_dir("render", fn dir ->
        File.write!(Path.join(dir, "out.png"), data)
      end)
  """
  @spec with_scratch_dir(purpose :: String.t(), fun :: (String.t() -> result)) :: result
        when result: term()
  def with_scratch_dir(purpose, fun) when is_binary(purpose) and is_function(fun, 1) do
    adapter().with_scratch_dir(purpose, fun)
  end

  @doc """
  Opens a native file-picker dialog for opening.

  Desktop adapters only.  Web adapters return `{:error, :unsupported}`.
  """
  @spec pick_open(opts :: keyword()) :: {:ok, Ref.t()} | {:error, term()}
  def pick_open(opts \\ []) do
    adapter().pick_open(opts)
  end

  @doc """
  Opens a native file-picker dialog for saving.

  Desktop adapters only.  Web adapters return `{:error, :unsupported}`.
  """
  @spec pick_save(opts :: keyword()) :: {:ok, Ref.t()} | {:error, term()}
  def pick_save(opts \\ []) do
    adapter().pick_save(opts)
  end

  @doc """
  Lists entries inside a ref that acts as a directory.
  """
  @spec list_dir(ref :: Ref.t()) :: {:ok, [Ref.t()]} | {:error, term()}
  def list_dir(%Ref{} = ref) do
    adapter().list_dir(ref)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  @doc false
  def adapter do
    Application.fetch_env!(:quire, :storage_adapter)
  end
end
