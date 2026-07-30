defmodule Quire.Editing.Ops.LinkEdit do
  @moduledoc false

  @doc """
  Validates and applies a link.edit operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of link.edit.
  Phase 0 placeholder — real undo needs the prior link state.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
