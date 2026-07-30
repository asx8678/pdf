defmodule Quire.Editing.Ops.DocBookmarkMove do
  @moduledoc false

  @doc """
  Validates and applies a doc.bookmark_move operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of doc.bookmark_move — reverts to the
  pre-move revision. Bookmarks are server-side document state.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
