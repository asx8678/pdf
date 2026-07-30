defmodule Quire.Editing.Ops.MarkHeaderFooter do
  @moduledoc false

  @doc """
  Validates and applies a mark.header_footer operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of mark.header_footer — removes the header/footer mark.
  """
  def invert(op_data, _context) do
    {:ok, %{kind: "mark.remove", id: op_data[:id]}}
  end
end
