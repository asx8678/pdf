defmodule Quire.Editing.Ops.PageMove do
  @moduledoc false

  @doc """
  Validates and applies a page.move operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of page.move.
  Phase 0 placeholder — real undo needs the prior page order.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
