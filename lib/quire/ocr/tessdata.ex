defmodule Quire.Ocr.Tessdata do
  @moduledoc ~S"""
  On-demand tessdata pack download, cache, and disk-usage management (§T-141).

  ## Overview

  When a user selects an OCR language whose `.traineddata` file is not yet
  installed, this module downloads it from the upstream
  [tessdata_fast](https://github.com/tesseract-ocr/tessdata_fast) repository,
  caches it in `Quire.Storage`, and materialises it to a local cache directory
  where Tesseract can find it.

  ## Cache directory

  The tessdata cache lives at `<app_data_dir>/tessdata/` (default
  `_data/tessdata/`).  On first use the module:

    1. Creates the cache directory.
    2. Symlinks `eng.traineddata` from `image_ocr`'s vendored path.
    3. Symlinks `osd.traineddata` from the Homebrew tessdata directory (if
       present), so automatic page-rotation (`psm: :auto_osd`) keeps working.
    4. Sets `config :image_ocr, :tessdata_path` to point at this cache
       directory so that every subsequent `Image.OCR.new(...)` picks up both
       system and downloaded packs without any code changes.

  After initialisation the cache looks like a complete tessdata directory and
  `Image.OCR.Tessdata.installed_languages()` reports everything in it.

  ## Storage

  Each downloaded pack is also stored as a blob in `Quire.Storage` so the
  cache directory can be repaired or rebuilt without re-downloading.

  ## Usage

      # Ensure a language is available before OCR
      Quire.Ocr.Tessdata.ensure("fra")

      # List everything available (system + cached)
      Quire.Ocr.Tessdata.list_available()

      # Disk usage
      Quire.Ocr.Tessdata.disk_usage()

      # Remove a cached pack
      Quire.Ocr.Tessdata.remove("fra")
  """

  alias Quire.Storage

  @manifest_name "tessdata_manifest.json"

  @tessdata_repo "https://github.com/tesseract-ocr/tessdata_fast/raw/main"

  @download_timeout 60_000
  @connect_timeout 15_000

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Returns the list of language codes that are available for OCR.

  Combines packs that are already in the system tessdata path with packs
  that have been downloaded and cached.

  ## Returns

  A sorted list of language code strings (e.g. `["deu", "eng", "fra"]`).
  """
  @spec list_available() :: [String.t()]
  def list_available do
    init!()
    system = Image.OCR.Tessdata.installed_languages(datapath: cache_root())
    cached = cached_languages()
    (system ++ cached) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  Downloads a `.traineddata` pack for `lang` from the upstream repository.

  Returns the raw binary with its SHA-256 hash and size.  Does **not**
  cache the result — call `cache/2` or `ensure/1` for that.

  ## Configuration

  The download URL can be overridden in application config:

      config :quire, :tessdata_mirror, "https://internal-mirror.example.com/tessdata_fast/raw/main"

  The default is `<https://github.com/tesseract-ocr/tessdata_fast/raw/main>`.

  ## Timeouts

  * Connect timeout: #{div(@connect_timeout, 1000)} s
  * Overall response timeout: #{div(@download_timeout, 1000)} s
  """
  @spec download(lang :: String.t()) ::
          {:ok, %{binary: binary(), sha256: String.t(), byte_size: pos_integer()}}
          | {:error, term()}
  def download(lang) when is_binary(lang) do
    url = download_url(lang)

    with {:ok, body} <- http_get(url) do
      sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      {:ok, %{binary: body, sha256: sha, byte_size: byte_size(body), source: url}}
    end
  end

  @doc """
  Caches a previously downloaded `binary` for `lang` both in `Quire.Storage`
  and in the local tessdata cache directory.

  The Storage blob is the canonical copy; the cache-directory file is what
  Tesseract reads at initialisation time.

  ## Returns

  `{:ok, ref}` where `ref` is the `Quire.Storage.Ref` for the blob.
  """
  @spec cache(lang :: String.t(), binary :: binary()) :: {:ok, Storage.Ref.t()} | {:error, term()}
  def cache(lang, binary) when is_binary(lang) and is_binary(binary) do
    init!()

    with {:ok, ref} <- store_in_storage(lang, binary),
         :ok <- write_to_cache(lang, binary) do
      record_cached(lang, ref)
      {:ok, ref}
    end
  end

  @doc """
  Returns the total number of bytes used by cached tessdata packs.

  Includes only packs stored in the local cache directory.  System-installed
  packs (vendored `eng`, Homebrew `osd`, etc.) are excluded.
  """
  @spec disk_usage() :: non_neg_integer()
  def disk_usage do
    init!()

    cache_root()
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".traineddata"))
    |> Enum.map(fn name ->
      path = Path.join(cache_root(), name)

      case File.stat(path) do
        {:ok, stat} -> stat.size
        {:error, _} -> 0
      end
    end)
    |> Enum.sum()
  end

  @doc """
  Removes a cached pack for `lang` from both Storage and the local cache
  directory.

  If the pack is a system-installed one (e.g. `eng`, `osd`) it is **not**
  removed from the system; only the cached copy is deleted.

  Returns `:ok` even when the pack was not cached (idempotent).
  """
  @spec remove(lang :: String.t()) :: :ok
  def remove(lang) when is_binary(lang) do
    init!()

    # Remove from local cache
    cache_path = local_path(lang)

    case File.rm(cache_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end

    # Remove from Storage
    case find_storage_ref(lang) do
      {:ok, ref} -> Storage.delete(ref)
      :error -> :ok
    end

    unrecord_cached(lang)
    :ok
  end

  @doc """
  Ensures that the traineddata for `lang` is available for Tesseract.

  ## Checks (in order)

  1. Is the pack already installed in the system tessdata path? → `:ok`
  2. Is the pack in the local cache directory? → `:ok`
  3. Is the pack in Storage (previously downloaded)? → restore to cache → `:ok`
  4. Otherwise → download from upstream, cache, → `:ok`

  ## Returns

  * `{:ok, :already_installed}` — pack was already available to Tesseract.
  * `{:ok, :cached}` — pack was in Storage and has been restored to cache.
  * `{:ok, :downloaded}` — pack was downloaded from upstream and cached.
  * `{:error, reason}` — something went wrong (network, hash mismatch, etc.).
  """
  @spec ensure(lang :: String.t()) ::
          {:ok, :already_installed | :cached | :downloaded} | {:error, term()}
  def ensure(lang) when is_binary(lang) do
    init!()

    cond do
      Image.OCR.Tessdata.installed?(lang, datapath: cache_root()) ->
        {:ok, :already_installed}

      cached_locally?(lang) ->
        {:ok, :already_installed}

      true ->
        case find_storage_ref(lang) do
          {:ok, ref} ->
            with {:ok, binary} <- Storage.get(ref),
                 :ok <- write_to_cache(lang, binary) do
              record_cached(lang, ref)
              {:ok, :cached}
            end

          :error ->
            with {:ok, %{binary: binary}} <- download(lang),
                 {:ok, _ref} <- cache(lang, binary) do
              {:ok, :downloaded}
            end
        end
    end
  end

  @doc """
  Returns the list of languages that have been explicitly cached (not
  counting system-installed packs like `eng` or `osd`).

  ## Returns

  A sorted list of language code strings.
  """
  @spec cached_languages() :: [String.t()]
  def cached_languages do
    manifest()
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Ensures that all languages in `langs` are available for Tesseract.

  Calls `ensure/1` for each language that is not already installed or cached.
  Returns `:ok` when all languages are ready, or `{:error, {lang, reason}}` on
  the first failure.

  ## Examples

      Tessdata.ensure_all(["eng", "fra", "deu"])
  """
  @spec ensure_all(langs :: [String.t()]) :: :ok | {:error, {String.t(), term()}}
  def ensure_all(langs) when is_list(langs) do
    result =
      Enum.reduce_while(langs, :ok, fn lang, _acc ->
        case ensure(lang) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {lang, reason}}}
        end
      end)

    case result do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns the path to the tessdata cache directory.

  This directory is set as `config :image_ocr, :tessdata_path` after
  initialisation, so Tesseract discovers every pack placed there.
  """
  @spec cache_root() :: String.t()
  def cache_root do
    data_root = storage_data_root()
    Path.join(Path.dirname(data_root), "tessdata")
  end

  # ── Initialisation ────────────────────────────────────────────────────

  @doc false
  def init! do
    case :persistent_term.get({__MODULE__, :initialized}, false) do
      true ->
        :ok

      false ->
        do_init()
    end
  end

  defp do_init do
    dir = cache_root()
    File.mkdir_p!(dir)

    # Symlink system-installed packs into the cache directory so that
    # Tesseract finds them through our single datapath.
    symlink_system_pack("eng", Image.OCR.Tessdata.vendored_path())
    symlink_system_pack("osd", system_tessdata_dir())

    # Configure image_ocr to use our cache directory as its datapath.
    Application.put_env(:image_ocr, :tessdata_path, dir)

    # Load the cached-languages manifest (Storage refs).
    load_manifest()

    :persistent_term.put({__MODULE__, :initialized}, true)
    :ok
  end

  defp symlink_system_pack(lang, source_dir) when is_binary(source_dir) do
    source = Path.join(source_dir, "#{lang}.traineddata")
    target = local_path(lang)

    if File.exists?(source) and not File.exists?(target) do
      File.ln_s!(source, target)
    end
  rescue
    # Symlink may fail if source_dir doesn't exist at all (e.g. Homebrew
    # not installed).  That's fine — the pack simply won't be in our cache.
    _ -> :ok
  end

  # ── Storage helpers ──────────────────────────────────────────────────

  defp store_in_storage(lang, binary) do
    Storage.put(binary,
      name: "tessdata_#{lang}.traineddata",
      content_type: "application/octet-stream",
      meta: %{language: lang, type: "tessdata"}
    )
  end

  defp find_storage_ref(lang) do
    manifest = manifest()

    case Map.fetch(manifest, lang) do
      {:ok, info} ->
        ref = %Storage.Ref{
          adapter: Quire.Storage.Web,
          key: info["key"],
          name: "tessdata_#{lang}.traineddata",
          byte_size: info["byte_size"]
        }

        {:ok, ref}

      :error ->
        :error
    end
  end

  # ── Local cache file helpers ─────────────────────────────────────────

  defp local_path(lang) do
    Path.join(cache_root(), "#{lang}.traineddata")
  end

  defp cached_locally?(lang) do
    File.exists?(local_path(lang))
  end

  defp write_to_cache(lang, binary) do
    path = local_path(lang)

    # Atomically write: temp file then rename so a crash never leaves
    # a half-written traineddata file.
    tmp = path <> ".tmp." <> random_suffix()
    File.write!(tmp, binary)
    File.rename!(tmp, path)

    :ok
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(4) |> Base.encode32(case: :lower)
  end

  # ── Manifest (persistent index of cached packs) ──────────────────────

  # The manifest is a small JSON object stored in the cache directory,
  # mapping language code → Storage ref info.  It is the sole mechanism
  # for recovering the list of cached packs after a cold restart without
  # scanning every possible key.

  defp manifest do
    case :persistent_term.get({__MODULE__, :manifest}, nil) do
      nil -> load_manifest()
      m -> m
    end
  end

  defp load_manifest do
    path = manifest_path()

    data =
      case File.read(path) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, map} -> map
            {:error, _} -> %{}
          end

        {:error, _} ->
          %{}
      end

    :persistent_term.put({__MODULE__, :manifest}, data)
    data
  end

  defp save_manifest do
    data = :persistent_term.get({__MODULE__, :manifest}, %{})
    json = Jason.encode!(data)
    path = manifest_path()

    tmp = path <> ".tmp." <> random_suffix()
    File.write!(tmp, json)
    File.rename!(tmp, path)

    :ok
  end

  defp manifest_path do
    Path.join(cache_root(), @manifest_name)
  end

  defp record_cached(lang, ref) do
    data = manifest()
    data = Map.put(data, lang, %{"key" => ref.key, "byte_size" => ref.byte_size})

    :persistent_term.put({__MODULE__, :manifest}, data)
    save_manifest()
  end

  defp unrecord_cached(lang) do
    data = manifest()
    data = Map.delete(data, lang)

    :persistent_term.put({__MODULE__, :manifest}, data)
    save_manifest()
  end

  # ── HTTP download ─────────────────────────────────────────────────────

  defp download_url(lang) do
    mirror = Application.get_env(:quire, :tessdata_mirror, @tessdata_repo)
    "#{mirror}/#{lang}.traineddata"
  end

  defp http_get(url) do
    # Ensure inets and ssl are started (safe to call repeatedly).
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), [{~c"user-agent", ~c"quire-ocr/1.0"}]}

    http_opts = [
      autoredirect: true,
      timeout: @download_timeout,
      connect_timeout: @connect_timeout,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 5,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    options = [body_format: :binary]

    case :httpc.request(:get, request, http_opts, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # ── Path resolution ──────────────────────────────────────────────────

  defp storage_data_root do
    # The same root the Filesystem backend uses — our cache directory is
    # a sibling of the storage root.
    Storage.Web.Filesystem.root()
  end

  defp system_tessdata_dir do
    # image_ocr's default datapath resolution (vendored `priv/tessdata/`) or
    # a configured path.  This covers `eng` and any other packs the NIF was
    # built against.  We also check well-known Homebrew paths for `osd` and
    # other system-installed packs that the vendored directory lacks.
    default = Image.OCR.Tessdata.vendored_path()

    # Homebrew tessdata directory (osd.traineddata, etc.)
    brew_possible = [
      "/opt/homebrew/share/tessdata",
      "/usr/local/share/tessdata",
      "/usr/share/tesseract-ocr/5/tessdata",
      "/usr/share/tesseract-ocr/4.00/tessdata"
    ]

    brew_dir =
      Enum.find(brew_possible, fn path ->
        File.exists?(Path.join(path, "osd.traineddata"))
      end)

    # If the vendored path and the Homebrew path differ, Homebrew takes
    # precedence because `osd` must be found (§9.10 auto-rotate).
    brew_dir || default
  end
end
