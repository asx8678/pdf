defmodule Quire.Editing.Ops.FormDeleteField do
  @moduledoc false

  @doc """
  Validates and applies a form.delete_field operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of form.delete_field — re-adds the deleted field.
  The original field definition should have been preserved in op_data.
  """
  def invert(op_data, _context) do
    {:ok, Map.put(op_data, :kind, "form.add_field")}
  end
end
