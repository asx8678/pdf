defmodule QuireWeb.SignerController do
  @moduledoc """
  Public HTTP controller for serving documents to signers via their
  access token (§9.9).

  Used by the public signer LiveView at `/sign/:token` to display the
  envelope document in an embed or iframe. Authentication is via the
  signer's `access_token` rather than the user session.

  ## Routes

      GET /sign/:token/document
  """

  use QuireWeb, :controller

  alias Quire.Esign.{Envelope, Signer}
  alias Quire.Repo
  alias Quire.Documents
  alias Quire.Storage

  def show(conn, %{"token" => token}) do
    signer = Repo.get_by(Signer, access_token: token)

    with {:ok, _signer} <- validate_signer(signer),
         {:ok, envelope} <- validate_envelope(signer.envelope_id),
         {:ok, doc} <- fetch_document(envelope.document_id) do
      serve_document(conn, doc)
    else
      {:error, _} -> not_found(conn)
    end
  end

  defp validate_signer(nil), do: {:error, :not_found}

  defp validate_signer(%Signer{status: status}) when status in [:pending, :viewed],
    do: {:ok, true}

  defp validate_signer(_), do: {:error, :invalid}

  defp validate_envelope(envelope_id) when is_binary(envelope_id) do
    case Repo.get(Envelope, envelope_id) do
      %Envelope{status: status, document_id: doc_id}
      when status in [:sent, :partially_signed] and not is_nil(doc_id) ->
        {:ok, %{document_id: doc_id}}

      _ ->
        {:error, :not_found}
    end
  end

  defp validate_envelope(_), do: {:error, :not_found}

  defp fetch_document(nil), do: {:error, :not_found}

  defp fetch_document(doc_id) do
    case Repo.get(Quire.Documents.Document, doc_id) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  defp serve_document(conn, doc) do
    case Documents.current_revision(doc) do
      {:ok, rev} ->
        ref = Documents.Revision.storage_ref(rev)
        size = ref.byte_size || 0

        conn
        |> put_resp_content_type("application/pdf")
        |> put_resp_header("content-disposition", "inline; filename=\"#{doc.title}\"")
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-length", Integer.to_string(size))
        |> send_resp(200, read_content(ref))

      _ ->
        not_found(conn)
    end
  end

  defp read_content(ref) do
    Storage.with_local_path(ref, fn path ->
      File.read!(path)
    end)
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
    |> halt()
  end
end
