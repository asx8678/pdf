defmodule Quire.Render do
  @moduledoc """
  Rasterisation and extraction behaviour — PDFium NIF primary, client-side
  fallback (§7.3).

  ## Dispatch

  Every public function in this module looks up the active adapter at **runtime**
  via `Application.fetch_env!(:quire, :render_adapter)`.  Adapters may swap
  between a local PDFium NIF and a browser-based fallback.

  All document references are `Quire.Storage.Ref` values — opaque blobs, never
  raw filesystem paths.

  Every public function emits telemetry events through `Quire.Engine.trace/4`.
  """

  alias Quire.Storage.Ref

  # ── Callbacks ───────────────────────────────────────────────────────────

  @doc """
  Returns the number of pages in the document.
  """
  @callback page_count(ref :: Ref.t()) :: {:ok, pos_integer()} | {:error, term()}

  @doc """
  Returns page geometry for every page in the document.

  Each entry is a map with `:width`, `:height` (points) and `:rotate`
  (clockwise degrees, typically 0, 90, 180 or 270).
  """
  @callback page_geometry(ref :: Ref.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Renders a single page to a PNG binary.

  `page_num` is zero-based.  `opts` may include `:dpi` (default 150) or
  `:width` / `:height` for explicit output dimensions.
  """
  @callback render_page(ref :: Ref.t(), page_num :: non_neg_integer(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Produces thumbnail PNGs for one or more pages.

  `opts` may include:
    * `:pages` — list of zero-based page numbers (default `[0]`)
    * `:max_dimension` — cap the longer side in pixels (default 256)
  """
  @callback thumbnails(ref :: Ref.t(), opts :: keyword()) :: {:ok, [binary()]} | {:error, term()}

  @doc """
  Extracts text per page with per-span metadata.

  Returns a list of maps, each with `:page` (zero-based) and `:spans`.
  """
  @callback extract_text(ref :: Ref.t(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Searches document text, returning hits with `:page`, `:rect` and `:context`.
  """
  @callback search(ref :: Ref.t(), query :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Returns form field metadata for the document.

  Each entry is a map with `:type`, `:name`, `:value` and `:rect`.
  """
  @callback form_fields(ref :: Ref.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Returns annotation metadata per page.

  Each entry is a map with `:type`, `:contents` and `:rect`.
  """
  @callback annotations(ref :: Ref.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Extracts embedded raster images and stores them in the blob store.

  Returns a list of `{page_number, image_index_within_page, ref}` triples
  where each `ref` points to a PNG blob in Storage.
  """
  @callback extract_images(ref :: Ref.t(), opts :: keyword()) ::
              {:ok, [{non_neg_integer(), non_neg_integer(), Ref.t()}]} | {:error, term()}

  @doc """
  Returns the bookmark/outline tree for the document.

  Each entry is a map with `:title`, `:page` (destination page, zero-based),
  and `:children` (nested sub‑entries).  Read‑only — use `Quire.Pdf.Outline`
  for outline writes.
  """
  @callback outline(ref :: Ref.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Imports pages from `source_ref` into `dest_ref`.

  `page_nums` is a list of zero-based page numbers to import.
  Returns `{:ok, ref}` pointing to the resulting document.
  """
  @callback import_pages(
              source_ref :: Ref.t(),
              dest_ref :: Ref.t(),
              page_nums :: [non_neg_integer()]
            ) ::
              {:ok, Ref.t()} | {:error, term()}

  @doc """
  Creates a new empty document.

  `opts` may include `:format` (page size, e.g. `"A4"`), `:orientation` etc.
  Returns `{:ok, ref}` pointing to the new document.
  """
  @callback new_document(opts :: keyword()) :: {:ok, Ref.t()} | {:error, term()}

  @doc """
  Adds a blank page to an existing document.

  `page_size` is an atom like `:letter` or `:a4`.  Returns `{:ok, ref}`
  pointing to the updated document.
  """
  @callback add_page(ref :: Ref.t(), page_size :: atom(), opts :: keyword()) ::
              {:ok, Ref.t()} | {:error, term()}

  @doc """
  Serialises the document.

  `opts` may include `:format` (`:pdf` or `:pdfa`).  Returns `{:ok, ref}`
  pointing to the serialised output.
  """
  @callback save(ref :: Ref.t(), opts :: keyword()) :: {:ok, Ref.t()} | {:error, term()}

  # ── Public API — runtime dispatch ───────────────────────────────────────

  @doc """
  Returns the number of pages in the document.
  """
  @spec page_count(ref :: Ref.t()) :: {:ok, pos_integer()} | {:error, term()}
  def page_count(ref) do
    Quire.Engine.trace(__MODULE__, :page_count, [ref], fn ->
      adapter().page_count(ref)
    end)
  end

  @doc """
  Returns page geometry for every page in the document.

  Each entry is `%{width: float, height: float, rotate: non_neg_integer}`.
  """
  @spec page_geometry(ref :: Ref.t()) :: {:ok, [map()]} | {:error, term()}
  def page_geometry(ref) do
    Quire.Engine.trace(__MODULE__, :page_geometry, [ref], fn ->
      adapter().page_geometry(ref)
    end)
  end

  @doc """
  Renders `page_num` (zero‑based) to a PNG binary.

  Options:
    * `:dpi` — render resolution (default 150)
    * `:width` / `:height` — explicit output dimensions
  """
  @spec render_page(ref :: Ref.t(), page_num :: non_neg_integer(), opts :: keyword()) ::
          {:ok, binary()} | {:error, term()}
  def render_page(ref, page_num, opts \\ []) do
    Quire.Engine.trace(__MODULE__, :render_page, [ref, page_num, opts], fn ->
      adapter().render_page(ref, page_num, opts)
    end)
  end

  @doc """
  Produces thumbnail PNGs.

  Options:
    * `:pages` — list of zero‑based page numbers (default `[0]`)
    * `:max_dimension` — cap the longer side in pixels (default 256)
  """
  @spec thumbnails(ref :: Ref.t(), opts :: keyword()) :: {:ok, [binary()]} | {:error, term()}
  def thumbnails(ref, opts \\ []) do
    Quire.Engine.trace(__MODULE__, :thumbnails, [ref, opts], fn ->
      adapter().thumbnails(ref, opts)
    end)
  end

  @doc """
  Extracts text per page with span metadata.

  Options:
    * `:repair` — run the text‑repair pass (default false)
  """
  @spec extract_text(ref :: Ref.t(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  def extract_text(ref, opts \\ []) do
    Quire.Engine.trace(__MODULE__, :extract_text, [ref, opts], fn ->
      adapter().extract_text(ref, opts)
    end)
  end

  @doc """
  Searches document text.

  Returns hits with `:page`, `:rect` and `:context`.
  """
  @spec search(ref :: Ref.t(), query :: String.t(), opts :: keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search(ref, query, opts \\ []) do
    Quire.Engine.trace(__MODULE__, :search, [ref, query, opts], fn ->
      adapter().search(ref, query, opts)
    end)
  end

  @doc """
  Returns form field metadata (type, name, value, rect).
  """
  @spec form_fields(ref :: Ref.t()) :: {:ok, [map()]} | {:error, term()}
  def form_fields(ref) do
    Quire.Engine.trace(__MODULE__, :form_fields, [ref], fn ->
      adapter().form_fields(ref)
    end)
  end

  @doc """
  Returns annotation metadata per page.
  """
  @spec annotations(ref :: Ref.t()) :: {:ok, [map()]} | {:error, term()}
  def annotations(ref) do
    Quire.Engine.trace(__MODULE__, :annotations, [ref], fn ->
      adapter().annotations(ref)
    end)
  end

  @doc """
  Extracts embedded raster images, storing each as a blob.

  Returns a list of `{page_number, image_index_within_page, ref}` triples.
  Page numbers are zero-based; image indices are zero-based within each page.
  """
  @spec extract_images(ref :: Ref.t(), opts :: keyword()) ::
          {:ok, [{non_neg_integer(), non_neg_integer(), Ref.t()}]} | {:error, term()}
  def extract_images(ref, opts \\ []) do
    Quire.Engine.trace(__MODULE__, :extract_images, [ref, opts], fn ->
      adapter().extract_images(ref, opts)
    end)
  end

  @doc """
  Returns the bookmark/outline tree.

  Each entry has `:title`, `:page` and `:children`.
  """
  @spec outline(ref :: Ref.t()) :: {:ok, [map()]} | {:error, term()}
  def outline(ref) do
    Quire.Engine.trace(__MODULE__, :outline, [ref], fn ->
      adapter().outline(ref)
    end)
  end

  @doc """
  Imports pages from `source_ref` into `dest_ref`.
  """
  @spec import_pages(source_ref :: Ref.t(), dest_ref :: Ref.t(), page_nums :: [non_neg_integer()]) ::
          {:ok, Ref.t()} | {:error, term()}
  def import_pages(source_ref, dest_ref, page_nums) do
    Quire.Engine.trace(__MODULE__, :import_pages, [source_ref, dest_ref, page_nums], fn ->
      adapter().import_pages(source_ref, dest_ref, page_nums)
    end)
  end

  @doc """
  Creates a new empty document.
  """
  @spec new_document(opts :: keyword()) :: {:ok, Ref.t()} | {:error, term()}
  def new_document(opts \\ []) do
    Quire.Engine.trace(__MODULE__, :new_document, [opts], fn ->
      adapter().new_document(opts)
    end)
  end

  @doc """
  Adds a blank page to a document.

  `page_size` is an atom like `:letter` or `:a4`.  `opts` may include
  `:page` (zero-based index at which to insert the new page).
  """
  @spec add_page(ref :: Ref.t(), page_size :: atom(), opts :: keyword()) ::
          {:ok, Ref.t()} | {:error, term()}
  def add_page(ref, page_size, opts \\ []) do
    Quire.Engine.trace(__MODULE__, :add_page, [ref, page_size, opts], fn ->
      adapter().add_page(ref, page_size, opts)
    end)
  end

  @doc """
  Serialises the document.

  Options:
    * `:format` — `:pdf` (default) or `:pdfa`
  """
  @spec save(ref :: Ref.t(), opts :: keyword()) :: {:ok, Ref.t()} | {:error, term()}
  def save(ref, opts \\ []) do
    Quire.Engine.trace(__MODULE__, :save, [ref, opts], fn ->
      adapter().save(ref, opts)
    end)
  end

  # ── Boot self‑check ─────────────────────────────────────────────────────

  @doc false
  def check do
    adapter().check()
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  @doc false
  def adapter do
    Application.fetch_env!(:quire, :render_adapter)
  end
end
