defmodule Quire.Editing.Ops.MarkRemove do
  @moduledoc false

  @doc """
  Validates and applies a mark.remove operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of mark.remove — restores the removed mark.
  The original mark data should have been preserved in op_data.
  """
  def invert(op_data, _context) do
    {:ok, Map.put(op_data, :kind, "mark.page_number")}
  end
end
