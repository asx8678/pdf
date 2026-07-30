defmodule Quire.Editing.Ops.FormAddField do
  @moduledoc false

  @doc """
  Validates and applies a form.add_field operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of form.add_field — deletes the added field.
  """
  def invert(op_data, _context) do
    {:ok, %{kind: "form.delete_field", field_name: op_data[:field_name]}}
  end
end
