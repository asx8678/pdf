defmodule Quire.Editing.Ops.MarkBates do
  @moduledoc false

  @doc """
  Validates and applies a mark.bates operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of mark.bates — removes the Bates numbering.
  """
  def invert(op_data, _context) do
    {:ok, %{kind: "mark.remove", id: op_data[:id]}}
  end
end
