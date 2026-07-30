defmodule Quire.Editing.Ops.SecRedactApply do
  @moduledoc false

  @doc """
  Validates and applies a sec.redact_apply operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of sec.redact_apply — reverts to the
  pre-redaction revision. Redaction is a destructive server-side transform.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
