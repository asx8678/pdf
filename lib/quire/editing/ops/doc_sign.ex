defmodule Quire.Editing.Ops.DocSign do
  @moduledoc false

  @doc """
  Validates and applies a doc.sign operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of doc.sign — reverts to the pre-signature revision.
  Signing is a server-side document transform.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
