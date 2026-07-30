defmodule Quire.Editing.Ops.AnnotReply do
  @moduledoc false

  @doc """
  Validates and applies an annot.reply operation.
  """
  def apply(op_data, _context) do
    {:ok, op_data}
  end

  @doc """
  Computes the inverse of annot.reply — deletes the reply that was added.
  Uses the annot.delete kind since no separate reply-delete kind exists.
  """
  def invert(op_data, _context) do
    {:ok, %{kind: "annot.delete", id: op_data[:id]}}
  end
end
