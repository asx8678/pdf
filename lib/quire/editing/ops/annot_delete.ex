defmodule Quire.Editing.Ops.AnnotDelete do
  @moduledoc false

  @doc """
  Validates and applies an annot.delete operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of annot.delete — must restore the deleted annotation.
  The original annotation data should have been preserved in op_data.
  """
  def invert(op_data, _context) do
    {:ok, Map.put(op_data, :kind, "annot.add")}
  end
end
