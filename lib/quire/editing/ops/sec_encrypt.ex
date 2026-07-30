defmodule Quire.Editing.Ops.SecEncrypt do
  @moduledoc false

  @doc """
  Validates and applies a sec.encrypt operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of sec.encrypt — reverts to the unencrypted revision.
  Document-level encryption is a server-side transform.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
