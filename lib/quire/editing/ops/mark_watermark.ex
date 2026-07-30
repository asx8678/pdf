defmodule Quire.Editing.Ops.MarkWatermark do
  @moduledoc false

  @doc """
  Validates and applies a mark.watermark operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of mark.watermark — removes the watermark.
  """
  def invert(op_data, _context) do
    {:ok, %{kind: "mark.remove", id: op_data[:id]}}
  end
end
