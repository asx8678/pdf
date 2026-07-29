defmodule Quire.Storage.Local do
  @moduledoc """
  Desktop-application storage adapter (§7.1, §12).

  Implements `Quire.Storage` with plain `File.*` operations.  `Ref.key` is
  an **absolute filesystem path** — the caller is responsible for choosing
  the path (typically via a native file-picker dialog on the desktop shell).

  `pick_open/1` and `pick_save/1` require a LiveView-connected client
  (Phase 13 / Tauri).  In Phase 0 they return `{:error, :unsupported}` and
  callers fall back to the web-upload or `send_download` path.

  ## Key contract (§7.1)

  - `Ref.key` is an absolute path.  Nothing outside the adapter may inspect
    or derive meaning from it — download headers use `Ref.name`.
  - `with_local_path/2` is the cheap case: the file is already local, so
    the real path is handed over without a copy.
  """

  @behaviour Quire.Storage

  alias Quire.Storage.Ref

  @impl true
  def put(data, opts \\ []) do
    path = opts[:path]

    if is_nil(path) do
      {:error, :path_required}
    else
      dir = Path.dirname(path)
      File.mkdir_p!(dir)

      tmp = path <> ".tmp." <> random_suffix()
      File.write!(tmp, data)
      File.rename!(tmp, path)

      ref = %Ref{
        adapter: __MODULE__,
        key: path,
        name: opts[:name] || Path.basename(path),
        content_type: opts[:content_type],
        byte_size: byte_size(data),
        meta: opts[:meta]
      }

      {:ok, ref}
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def get(%Ref{key: path}) do
    {:ok, File.read!(path)}
  rescue
    e -> {:error, e}
  end

  @impl true
  def stream(%Ref{key: path}, chunk_size \\ 65_536) do
    File.stream!(path, chunk_size, [])
  end

  @impl true
  def delete(%Ref{key: path}) do
    File.rm!(path)
    :ok
  rescue
    e -> {:error, e}
  end

  @impl true
  def size(%Ref{key: path}) do
    {:ok, File.stat!(path).size}
  rescue
    e -> {:error, e}
  end

  @impl true
  def name(%Ref{name: name}), do: name

  @impl true
  def with_local_path(%Ref{key: path}, fun) when is_function(fun, 1) do
    fun.(path)
  end

  @impl true
  def with_local_paths(refs, fun) when is_list(refs) and is_function(fun, 1) do
    paths = Enum.map(refs, fn %Ref{key: path} -> path end)
    fun.(paths)
  end

  @impl true
  def with_scratch_dir(purpose, fun) when is_binary(purpose) and is_function(fun, 1) do
    dir = scratch_path(purpose)
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  @impl true
  def pick_open(_opts \\ []), do: {:error, :unsupported}

  @impl true
  def pick_save(_opts \\ []), do: {:error, :unsupported}

  @impl true
  def list_dir(%Ref{key: path}) do
    case File.ls(path) do
      {:ok, entries} ->
        refs =
          Enum.flat_map(entries, fn entry ->
            child_path = Path.join(path, entry)

            case File.stat(child_path) do
              {:ok, %{type: :directory}} ->
                [
                  %Ref{
                    adapter: __MODULE__,
                    key: child_path,
                    name: entry
                  }
                ]

              {:ok, stat} ->
                [
                  %Ref{
                    adapter: __MODULE__,
                    key: child_path,
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

  defp random_suffix do
    :crypto.strong_rand_bytes(4) |> Base.encode32(case: :lower)
  end

  defp scratch_path(purpose) when is_binary(purpose) do
    ts = System.system_time(:millisecond)
    rand = :rand.uniform(1_000_000)

    Path.join(
      System.tmp_dir!(),
      "quire_local_scratch_" <>
        purpose <> "_" <> Integer.to_string(ts) <> "_" <> Integer.to_string(rand)
    )
  end
end
