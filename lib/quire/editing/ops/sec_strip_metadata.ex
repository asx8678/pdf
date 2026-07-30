defmodule Quire.Editing.Ops.SecStripMetadata do
  @moduledoc false

  @doc """
  Validates and applies a sec.strip_metadata operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of sec.strip_metadata.
  Phase 0 placeholder — real undo needs the prior metadata.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
