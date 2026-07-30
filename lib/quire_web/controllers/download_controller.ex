defmodule QuireWeb.DownloadController do
  @moduledoc """
  Serves Storage blobs as downloadable files.

  ## Routes

      GET /download/zip/:uuid

  The `uuid` is the last segment of a `Storage.Web.Filesystem` fan‑out key;
  the controller reconstructs the full path and streams the file.
  """

  use QuireWeb, :controller

  alias Quire.Storage

  @doc """
  Serve a ZIP blob as a file download.
  """
  def zip(conn, %{"uuid" => uuid}) do
    first2 = String.slice(uuid, 0, 2)
    next2 = String.slice(uuid, 2, 2)
    key = "#{first2}/#{next2}/#{uuid}"

    ref = %Storage.Ref{
      adapter: Quire.Storage.Web,
      key: key,
      name: "exported_images.zip",
      content_type: "application/zip"
    }

    filename = ref.name

    Storage.with_local_path(ref, fn path ->
      conn
      |> put_resp_content_type("application/zip")
      |> put_resp_header(
        "content-disposition",
        ~s|attachment; filename="#{filename}"|
      )
      |> send_file(200, path)
    end)
  rescue
    RuntimeError ->
      conn |> put_status(:not_found) |> json(%{error: "not_found"}) |> halt()

    e ->
      conn |> put_status(:internal_server_error) |> json(%{error: inspect(e)}) |> halt()
  end
end
