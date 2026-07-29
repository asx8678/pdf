defmodule Quire.Render do
  @moduledoc """
  Rasterisation and extraction behaviour — PDFium NIF primary, client-side
  fallback (§7.3).

  Every callback returns plain data; document references are handled via
  `Quire.Storage.Ref`.
  """

  @doc """
  Returns the number of pages in the document.
  """
  @callback page_count(ref :: term()) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Returns `{width, height}` per page (points).
  """
  @callback page_geometry(ref :: term()) ::
              {:ok, list({non_neg_integer(), non_neg_integer()})} | {:error, term()}

  @doc """
  Renders a page to PNG bytes at the given DPI.

  Returns `{:ok, png_binary}` or `{:error, reason}`.
  """
  @callback render_page(ref :: term(), page :: non_neg_integer(), dpi :: pos_integer()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Produces thumbnail PNGs for the given pages.

  `pages` is a list of zero-based page numbers; `max_dimension` caps the
  longer side in pixels. Returns `{:ok, list(binary())}` in page order.
  """
  @callback thumbnails(
              ref :: term(),
              pages :: [non_neg_integer()],
              max_dimension :: pos_integer()
            ) ::
              {:ok, list(binary())} | {:error, term()}

  @doc """
  Extracts text per page with per-span bounding boxes.

  Returns `{:ok, list(map())}` where each element represents a page's text
  spans.
  """
  @callback extract_text(ref :: term(), opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc """
  Searches document text, returning hits with page, rect and context.
  """
  @callback search(ref :: term(), query :: String.t(), opts :: keyword()) ::
              {:ok, list(map())} | {:error, term()}

  @doc """
  Returns form field metadata for the document.
  """
  @callback form_fields(ref :: term()) :: {:ok, list(map())} | {:error, term()}

  @doc """
  Returns annotation metadata per page.
  """
  @callback annotations(ref :: term()) :: {:ok, list(map())} | {:error, term()}

  @doc """
  Extracts embedded raster images at native resolution.
  """
  @callback extract_images(ref :: term(), opts :: keyword()) ::
              {:ok, list(binary())} | {:error, term()}

  @doc """
  Returns the bookmark/outline tree for the document.

  Read-only — use `Quire.Pdf.Outline` for outline writes.
  """
  @callback outline(ref :: term()) :: {:ok, term()} | {:error, term()}

  @doc """
  Imports pages from another document.
  """
  @callback import_pages(dest :: term(), source :: term(), pages :: [non_neg_integer()]) ::
              {:ok, term()} | {:error, term()}

  @callback new_document(opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @callback add_page_objects(doc :: term(), objects :: term()) :: {:ok, term()} | {:error, term()}

  @callback save(doc :: term()) :: {:ok, binary()} | {:error, term()}

  @doc false
  def check, do: Quire.Render.Pdfium.check()
end
