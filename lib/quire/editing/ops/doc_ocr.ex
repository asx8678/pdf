defmodule Quire.Editing.Ops.DocOcr do
  @moduledoc false

  @doc """
  Validates and applies a doc.ocr operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of doc.ocr — reverts to the pre-OCR revision.
  OCR is a server-side document transform.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
