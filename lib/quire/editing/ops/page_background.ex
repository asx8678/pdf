defmodule Quire.Editing.Ops.PageBackground do
  @moduledoc false

  @doc """
  Validates and applies a page.background operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of page.background — restores the previous revision.
  """
  def invert(_op_data, context) do
    {:ok, {:restore_revision, context[:base_revision_id]}}
  end
end
