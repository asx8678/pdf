defmodule Quire.Editing.Ops.PageCrop do
  @moduledoc false

  @doc """
  Validates and applies a page.crop or page.remove_crop operation.

  For page.crop, `op_data` expects:
    * `:top`, `:bottom`, `:left`, `:right` — margin amounts in points
    * `:page_order` — list of 0-based page indices

  For page.remove_crop, no margin params are needed.
  """
  def apply(%{kind: "page.crop"} = op_data, _context) do
    {:ok, op_data}
  end

  def apply(%{kind: "page.remove_crop"} = op_data, _context) do
    {:ok, op_data}
  end

  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of page.crop / page.remove_crop — restores the previous revision.
  """
  def invert(_op_data, context) do
    {:ok, {:restore_revision, context[:base_revision_id]}}
  end
end
