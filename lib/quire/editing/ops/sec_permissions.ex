defmodule Quire.Editing.Ops.SecPermissions do
  @moduledoc false

  @doc """
  Validates and applies a sec.permissions operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of sec.permissions.
  Phase 0 placeholder — real undo needs the prior permission flags.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
