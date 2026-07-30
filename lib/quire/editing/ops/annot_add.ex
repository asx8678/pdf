defmodule Quire.Editing.Ops.AnnotAdd do
  @moduledoc false

  @doc """
  Validates and applies an annot.add operation.
  Returns {:ok, result} | {:error, reason}.
  """
  def apply(op_data, _context) do
    # Phase 0: validate op data structure, return as-is.
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of annot.add — must delete what was added.
  """
  def invert(op_data, _context) do
    {:ok, %{kind: "annot.delete", id: op_data[:id]}}
  end
end
