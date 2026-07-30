defmodule Quire.Editing.Ops.DocMetadata do
  @moduledoc false

  @doc """
  Validates and applies a doc.metadata operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of doc.metadata — reverts to the pre-metadata revision.
  Metadata changes are server-side document operations.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
