defmodule Quire.Editing.Ops.PageCrop do
  @moduledoc false

  @doc """
  Validates and applies a page.crop operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of page.crop.
  Phase 0 placeholder — real undo needs the prior crop box.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
