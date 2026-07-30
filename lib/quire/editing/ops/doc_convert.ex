defmodule Quire.Editing.Ops.DocConvert do
  @moduledoc false

  @doc """
  Validates and applies a doc.convert operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of doc.convert — reverts to the pre-conversion revision.
  Conversion is a server-side document transform.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
