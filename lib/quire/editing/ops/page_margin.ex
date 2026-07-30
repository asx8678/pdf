defmodule Quire.Editing.Ops.PageMargin do
  @moduledoc false

  @doc """
  Validates and applies a page.margin operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of page.margin.
  Phase 0 placeholder — real undo needs the prior margin values.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
