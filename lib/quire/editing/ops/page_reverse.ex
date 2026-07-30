defmodule Quire.Editing.Ops.PageReverse do
  @moduledoc false

  @doc """
  Validates and applies a page.reverse operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of page.reverse.
  Reversing again restores the original order.
  Phase 0 placeholder.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
