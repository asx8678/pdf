defmodule Quire.Editing.Ops.SignaturePlace do
  @moduledoc """
  Validates and applies a `signature.place` operation (§9.4, T-115).

  The operation embeds a rasterised signature PNG onto a document page as a
  flattened image XObject, using `Quire.Pdf.SignatureFlatten`.  Placement is
  a server-side document transform: the client supplies the PDF points rect
  (converted via `viewport.convertToPdfPoint`, authoritative per §14.3) and
  the rasterised signature, and the server writes the flattened XObject and
  journals the change.

  ## Expected op_data fields

    * `"pdf_bytes"` — current revision bytes (required, injected by the caller)
    * `"page_index"` — zero-based target page (required)
    * `"rect"` — `[x0, y0, x1, y1]` in PDF points (required, x1 > x0, y1 > y0)
    * `"png"` — signature PNG bytes (required)

  ## Returns

    * `{:ok, embedded_bytes}` — the new document bytes with the signature
      flattened onto the page.
    * `{:error, reason}` — validation or embedding failure.
  """

  @doc """
  Validates and applies a `signature.place` operation.

  Returns `{:ok, embedded_bytes}` or `{:error, reason}`.
  """
  def apply(op_data, _context) do
    with {:ok, pdf_bytes} <- required(op_data, "pdf_bytes", :binary),
         {:ok, page_index} <- required(op_data, "page_index", :integer),
         {:ok, rect} <- required(op_data, "rect", :list),
         {:ok, png} <- required(op_data, "png", :binary) do
      Quire.Pdf.SignatureFlatten.place(pdf_bytes, page_index, rect, png)
    end
  end

  @doc """
  Computes the inverse of `signature.place` — reverts to the pre-place
  revision, since the signature is flattened into the page content.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end

  defp required(op_data, key, type) do
    value = Map.get(op_data, key) || Map.get(op_data, String.to_atom(key))

    cond do
      is_nil(value) ->
        {:error, "#{key} is required"}

      type == :binary and not is_binary(value) ->
        {:error, "#{key} must be a binary"}

      type == :integer and not is_integer(value) ->
        {:error, "#{key} must be an integer"}

      type == :list and not is_list(value) ->
        {:error, "#{key} must be a list"}

      true ->
        {:ok, value}
    end
  end
end
