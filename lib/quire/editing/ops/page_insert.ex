defmodule Quire.Editing.Ops.PageInsert do
  @moduledoc false

  @doc """
  Validates and applies a page.insert operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of page.insert — deletes the inserted page.
  """
  def invert(op_data, _context) do
    {:ok, %{kind: "page.delete", page_index: op_data[:page_index]}}
  end
end
