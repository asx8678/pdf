defmodule Quire.Editing.Ops.FormUpdateField do
  @moduledoc false

  @doc """
  Validates and applies a form.update_field operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of form.update_field.
  Phase 0 placeholder — real undo needs the prior field properties.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
