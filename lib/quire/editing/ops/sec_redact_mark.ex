defmodule Quire.Editing.Ops.SecRedactMark do
  @moduledoc false

  @doc """
  Validates and applies a sec.redact_mark operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of sec.redact_mark.
  No unmark counterpart exists in the catalogue, so uses
  restore_revision as a Phase 0 placeholder.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
