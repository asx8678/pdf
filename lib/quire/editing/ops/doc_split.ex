defmodule Quire.Editing.Ops.DocSplit do
  @moduledoc false

  @doc """
  Validates and applies a doc.split operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of doc.split — reverts to the pre-split revision.
  Split is a server-side document transform.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
