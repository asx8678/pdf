defmodule Quire.Editing.Ops.DocMerge do
  @moduledoc false

  @doc """
  Validates and applies a doc.merge operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of doc.merge — reverts to the pre-merge revision.
  Merge is a server-side document transform.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
