defmodule Quire.Editing.Ops.FormFill do
  @moduledoc false

  @doc """
  Validates and applies a form.fill operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of form.fill.
  Phase 0 placeholder — real undo needs the prior field values.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
