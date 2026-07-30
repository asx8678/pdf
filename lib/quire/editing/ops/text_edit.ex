defmodule Quire.Editing.Ops.TextEdit do
  @moduledoc false

  @doc """
  Validates and applies a text.edit operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of text.edit.
  Phase 0 placeholder — real undo needs the prior text captured at apply time.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
