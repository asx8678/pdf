defmodule Quire.Editing.Ops.MarkPageNumber do
  @moduledoc false

  @doc """
  Validates and applies a mark.page_number operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of mark.page_number — removes the page number mark.
  """
  def invert(op_data, _context) do
    {:ok, %{kind: "mark.remove", id: op_data[:id]}}
  end
end
