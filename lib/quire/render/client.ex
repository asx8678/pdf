defmodule Quire.Render.Client do
  @moduledoc """
  Browser-side rendering fallback.  When the PDFium NIF is unavailable,
  thumbnails are captured from the viewer hook's canvas and uploaded
  through Storage.  `extract_text` and other non-visual operations are
  unavailable under this fallback.

  Every callback returns `{:error, :unavailable}` — this module fulfils the
  `Quire.Render` behaviour contract structurally but cannot produce results
  without a connected browser client.
  """

  @behaviour Quire.Render

  @doc false
  def check, do: {:error, "not available without browser"}

  @impl Quire.Render
  def page_count(_ref), do: {:error, :unavailable}

  @impl Quire.Render
  def page_geometry(_ref), do: {:error, :unavailable}

  @impl Quire.Render
  def render_page(_ref, _page_num, _opts), do: {:error, :unavailable}

  @impl Quire.Render
  def thumbnails(_ref, _opts), do: {:error, :unavailable}

  @impl Quire.Render
  def extract_text(_ref, _opts), do: {:error, :unavailable}

  @impl Quire.Render
  def search(_ref, _query, _opts), do: {:error, :unavailable}

  @impl Quire.Render
  def form_fields(_ref), do: {:error, :unavailable}

  @impl Quire.Render
  def annotations(_ref), do: {:error, :unavailable}

  @impl Quire.Render
  def extract_images(_ref, _opts), do: {:error, :unavailable}

  @impl Quire.Render
  def outline(_ref), do: {:error, :unavailable}

  @impl Quire.Render
  def import_pages(_source_ref, _dest_ref, _page_nums), do: {:error, :unavailable}

  @impl Quire.Render
  def new_document(_opts), do: {:error, :unavailable}

  @impl Quire.Render
  def add_page(_ref, _page_size, _opts), do: {:error, :unavailable}

  @impl Quire.Render
  def save(_ref, _opts), do: {:error, :unavailable}
end
