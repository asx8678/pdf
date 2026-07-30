defmodule Quire.Editing.Ops.PageBackground do
  @moduledoc false

  @doc """
  Validates and applies a page.background operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of page.background.
  No delete counterpart exists for backgrounds in the catalogue,
  so uses restore_revision as a Phase 0 placeholder.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
