defmodule Quire.Storage.Web.Filesystem do
  @moduledoc """
  Filesystem backend for `Quire.Storage.Web` (§7.1).

  Keys are `<first2>/<next2>/<uuid>` two-level fan-out under a configurable
  root directory.  Writes go to a temp file and are renamed into place so a
  crash never leaves a half-written ref.  `with_local_path/2` is the cheap
  case — the file already *is* a local path — but callers must still treat
  the path as valid only inside the function.
  """

  alias Quire.Storage.Ref

  @doc """
  Stores `data` and returns `{:ok, %Ref{}}`.

  ## Options

    * `:name` — human-facing filename (defaults to the uuid portion of the key)
    * `:content_type` — MIME type
    * `:meta` — arbitrary metadata map
  """
  @spec put(binary(), keyword()) :: {:ok, Ref.t()} | {:error, term()}
  def put(data, opts \\ []) do
    key = generate_key()
    path = store_path(key)

    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    tmp = path <> ".tmp." <> random_suffix()
    File.write!(tmp, data)
    File.rename!(tmp, path)

    ref = %Ref{
      adapter: Quire.Storage.Web,
      key: key,
      name: opts[:name] || key |> String.split("/") |> List.last(),
      content_type: opts[:content_type],
      byte_size: byte_size(data),
      meta: opts[:meta]
    }

    {:ok, ref}
  rescue
    e -> {:error, e}
  end

  @doc """
  Retrieves the full content of the blob identified by `ref`.
  """
  @spec get(Ref.t()) :: {:ok, binary()} | {:error, term()}
  def get(%Ref{} = ref) do
    {:ok, File.read!(store_path(ref.key))}
  rescue
    e -> {:error, e}
  end

  @doc """
  Streams the blob content in `chunk_size`-byte chunks.
  """
  @spec stream(Ref.t(), pos_integer()) :: Enumerable.t()
  def stream(%Ref{} = ref, chunk_size \\ 65_536) do
    File.stream!(store_path(ref.key), chunk_size, [])
  end

  @doc """
  Deletes the blob identified by `ref`.
  """
  @spec delete(Ref.t()) :: :ok | {:error, term()}
  def delete(%Ref{} = ref) do
    File.rm!(store_path(ref.key))
    :ok
  rescue
    e -> {:error, e}
  end

  @doc """
  Returns `{:ok, byte_count}`.
  """
  @spec size(Ref.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def size(%Ref{} = ref) do
    {:ok, File.stat!(store_path(ref.key)).size}
  rescue
    e -> {:error, e}
  end

  @doc """
  Returns the human-facing name from the ref.
  """
  @spec name(Ref.t()) :: String.t()
  def name(%Ref{} = ref), do: ref.name

  @doc """
  Hands the real filesystem path to `fun`, no copy needed.

  **Callers must treat the path as valid only inside `fun`.**
  """
  @spec with_local_path(Ref.t(), (String.t() -> result)) :: result when result: term()
  def with_local_path(%Ref{} = ref, fun) when is_function(fun, 1) do
    fun.(store_path(ref.key))
  end

  @doc """
  Like `with_local_path/2` but for multiple refs.
  """
  @spec with_local_paths([Ref.t()], ([String.t()] -> result)) :: result when result: term()
  def with_local_paths(refs, fun) when is_list(refs) and is_function(fun, 1) do
    paths = Enum.map(refs, &store_path(&1.key))
    fun.(paths)
  end

  @doc """
  Creates a scratch directory, runs `fun`, removes the directory (even on crash).
  """
  @spec with_scratch_dir(String.t(), (String.t() -> result)) :: result when result: term()
  def with_scratch_dir(purpose, fun) when is_binary(purpose) and is_function(fun, 1) do
    dir = scratch_path(purpose)
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  @doc """
  Desktop-only; returns `{:error, :unsupported}` for the web adapter.
  """
  @spec pick_open(keyword()) :: {:error, :unsupported}
  def pick_open(_opts \\ []), do: {:error, :unsupported}

  @doc """
  Desktop-only; returns `{:error, :unsupported}` for the web adapter.
  """
  @spec pick_save(keyword()) :: {:error, :unsupported}
  def pick_save(_opts \\ []), do: {:error, :unsupported}

  @doc """
  Lists entries inside a directory ref.
  """
  @spec list_dir(Ref.t()) :: {:ok, [Ref.t()]} | {:error, term()}
  def list_dir(%Ref{} = ref) do
    path = store_path(ref.key)

    case File.ls(path) do
      {:ok, entries} ->
        refs =
          Enum.flat_map(entries, fn entry ->
            child_key = ref.key <> "/" <> entry
            child_path = store_path(child_key)

            case File.stat(child_path) do
              {:ok, %{type: :directory}} ->
                [
                  %Ref{
                    adapter: Quire.Storage.Web,
                    key: child_key,
                    name: entry
                  }
                ]

              {:ok, stat} ->
                [
                  %Ref{
                    adapter: Quire.Storage.Web,
                    key: child_key,
                    name: entry,
                    byte_size: stat.size
                  }
                ]

              {:error, _} ->
                []
            end
          end)

        {:ok, refs}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  @doc false
  def generate_key do
    uuid = Ecto.UUID.generate(version: 7)
    first2 = String.slice(uuid, 0, 2)
    next2 = String.slice(uuid, 2, 2)
    "#{first2}/#{next2}/#{uuid}"
  end

  @doc false
  def root do
    Application.get_env(:quire, :data_dir) ||
      System.get_env("QUIRE_DATA_DIR") ||
      Path.join(File.cwd!(), "_data/storage")
  end

  @doc false
  def store_path(key) when is_binary(key) do
    Path.join(root(), key)
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(4) |> Base.encode32(case: :lower)
  end

  @doc false
  def scratch_path(purpose) when is_binary(purpose) do
    ts = System.system_time(:millisecond)
    rand = :rand.uniform(1_000_000)

    Path.join(
      System.tmp_dir!(),
      "quire_" <> purpose <> "_" <> Integer.to_string(ts) <> "_" <> Integer.to_string(rand)
    )
  end
end
