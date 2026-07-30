defmodule Quire.Editing.Ops.AnnotUpdate do
  @moduledoc false

  @doc """
  Validates and applies an annot.update operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of annot.update — restores prior values.
  In Phase 0, this is a placeholder; real undo needs the original
  field values captured at apply time.
  """
  def invert(op_data, _context) do
    {:ok, %{kind: "annot.update", id: op_data[:id], prior: op_data[:prior]}}
  end
end
