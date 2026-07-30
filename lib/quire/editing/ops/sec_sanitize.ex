defmodule Quire.Editing.Ops.SecSanitize do
  @moduledoc false

  @doc """
  Validates and applies a sec.sanitize operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of sec.sanitize — reverts to the pre-sanitized revision.
  Sanitization is a destructive server-side transform.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
