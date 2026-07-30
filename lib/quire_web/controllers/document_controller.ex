defmodule QuireWeb.DocumentController do
  @moduledoc """
  HTTP range-request controller for PDF documents (§10.3).

  Serves the current revision of a document with:
  - `200 OK` with `Accept-Ranges: bytes` on un-ranged requests (chunked stream)
  - `206 Partial Content` on a valid `Range:` request (chunked stream with offset)
  - `304 Not Modified` on `If-None-Match`
  - `416 Range Not Satisfiable` on an invalid range

  The controller streams via `Storage.stream/2` and never loads the whole PDF
  into an Elixir binary (§14.2). Range requests materialise the file locally
  and seek to the offset using `:file.position` + `:file.read`.

  ## Routes

      GET /documents/:id/pdf
  """
  use QuireWeb, :controller

  alias Quire.Documents
  alias Quire.Documents.Revision
  alias Quire.Storage

  @chunk_size 65_536

  @doc """
  Serve the current revision of a document.
  """
  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {:ok, doc} <- Documents.get_document(id, scope),
         {:ok, rev} <- Documents.current_revision(doc),
         %Storage.Ref{} = ref <- Revision.storage_ref(rev) do
      serve_document(conn, doc, ref)
    else
      {:error, :not_found} -> not_found(conn)
      {:error, :forbidden} -> forbidden(conn)
      nil -> not_found(conn)
    end
  end

  # ── Response handling ──────────────────────────────────────────────────

  defp serve_document(conn, doc, ref) do
    etag = etag_for(doc)
    size = ref.byte_size || resolved_size(ref)

    case get_req_header(conn, "if-none-match") do
      [^etag] ->
        conn
        |> put_resp_header("etag", etag)
        |> put_resp_header("accept-ranges", "bytes")
        |> send_resp(304, "")

      _ ->
        do_serve(conn, ref, size, etag)
    end
  end

  defp do_serve(conn, ref, size, etag) do
    content_type = ref.content_type || "application/pdf"

    case get_req_header(conn, "range") do
      [range_header] ->
        case parse_range(range_header, size) do
          {:ok, start, end_} ->
            serve_range(conn, ref, etag, content_type, size, start, end_)

          {:error, :invalid_range} ->
            conn
            |> put_resp_header("content-range", "bytes */#{size}")
            |> send_resp(416, "")
        end

      [] ->
        serve_full(conn, ref, etag, content_type, size)
    end
  end

  defp serve_full(conn, ref, etag, content_type, size) do
    conn
    |> put_resp_header("etag", etag)
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_content_type(content_type)
    |> stream_as_chunks(Storage.stream(ref), 200)
  end

  defp serve_range(conn, ref, etag, content_type, size, start, end_) do
    content_length = end_ - start + 1

    conn
    |> put_resp_header("etag", etag)
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-range", "bytes #{start}-#{end_}/#{size}")
    |> put_resp_content_type(content_type)
    |> put_resp_header("content-length", Integer.to_string(content_length))
    |> stream_as_chunks(range_stream(ref, start, end_), 206)
  end

  # ── Chunked streaming ──────────────────────────────────────────────────



  # Stream an enumerable as chunked transfer encoding with HTTP 200.
  defp stream_ok(conn, enumerable) do
    {:ok, conn} = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce_while(enumerable, conn, fn chunk, conn ->
      case Plug.Conn.chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  # Stream an enumerable as chunked transfer encoding with HTTP 206.
  defp stream_partial(conn, enumerable) do
    {:ok, conn} = Plug.Conn.send_chunked(conn, 206)

    Enum.reduce_while(enumerable, conn, fn chunk, conn ->
      case Plug.Conn.chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  # For range requests, materialise the file locally and build a
  # byte-offset stream so we read only the requested bytes without loading
  # the whole file into memory.
  defp range_stream(ref, start, end_) do
    length = end_ - start + 1

    Stream.resource(
      fn ->
        Storage.with_local_path(ref, fn path ->
          {:ok, fd} = :file.open(path, [:raw, :read, :binary])
          {:ok, _} = :file.position(fd, {:bof, start})
          {fd, length}
        end)
      end,
      fn {fd, remaining} when remaining > 0 ->
        chunk_size = min(remaining, @chunk_size)

        case :file.read(fd, chunk_size) do
          {:ok, data} when data != "" ->
            read = byte_size(data)
            {[data], {fd, remaining - read}}

          {:ok, _} ->
            {[], {fd, 0}}

          {:error, _reason} ->
            {:halt, fd}
        end
      end,
      fn {fd, _} -> :file.close(fd) end
    )
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp etag_for(doc) do
    ts = DateTime.to_unix(doc.updated_at)
    ~s|"quire-#{doc.id}-#{ts}"|
  end

  defp resolved_size(ref) do
    case Storage.size(ref) do
      {:ok, size} -> size
      _ -> 0
    end
  end

  # Parse `Range: bytes=start-end` header.
  defp parse_range("bytes=" <> range, size) do
    case String.split(range, "-") do
      [start_str, ""] ->
        start = String.to_integer(start_str)
        if start < size and start >= 0, do: {:ok, start, size - 1}, else: {:error, :invalid_range}

      [start_str, end_str] ->
        start = String.to_integer(start_str)
        end_ = String.to_integer(end_str)

        if start >= 0 and end_ >= start and end_ < size,
          do: {:ok, start, end_},
          else: {:error, :invalid_range}

      _ ->
        {:error, :invalid_range}
    end
  end

  defp parse_range(_, _size), do: {:error, :invalid_range}

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"}) |> halt()

  defp forbidden(conn),
    do: conn |> put_status(:forbidden) |> json(%{error: "forbidden"}) |> halt()
end
