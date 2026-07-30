defmodule Quire.Editing.Ops.TextStyle do
  @moduledoc false

  @doc """
  Validates and applies a text.style operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of text.style.
  Phase 0 placeholder — real undo needs the prior style captured at apply time.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
