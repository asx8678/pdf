defmodule Quire.Editing.Ops.PageReplace do
  @moduledoc false

  @doc """
  Validates and applies a page.replace operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of page.replace.
  Phase 0 placeholder — real undo needs the original page content.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
