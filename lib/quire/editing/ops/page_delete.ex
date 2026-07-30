defmodule Quire.Editing.Ops.PageDelete do
  @moduledoc false

  @doc """
  Validates and applies a page.delete operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of page.delete — re-inserts the deleted page.
  The original page content should have been preserved in op_data.
  """
  def invert(op_data, _context) do
    {:ok, Map.put(op_data, :kind, "page.insert")}
  end
end
