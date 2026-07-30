defmodule Quire.Editing.Ops.PageRotate do
  @moduledoc false

  @doc """
  Validates and applies a page.rotate operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of page.rotate.
  Phase 0 placeholder — real undo needs the prior rotation value.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
