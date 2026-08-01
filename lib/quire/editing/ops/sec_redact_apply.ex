defmodule Quire.Editing.Ops.SecRedactApply do
  @moduledoc """
  Applies redaction marks to a document and persists a new revision.

  This is a **server-side destructive operation** — redaction is
  unrecoverable. The worker (`Quire.Workers.SecureWorker`) performs the
  actual PDF object removal and verification against the plan's Critical
  risk R-06.

  ## Operation data

      %{
        "marks" => [
          %{"page" => 0, "rect" => [x0, y0, x1, y1]},
          ...
        ]
      }

  Each mark must specify the zero-based `page` and the `rect` bounding box
  in PDF user-space points (bottom-left origin).
  """

  @doc """
  Validates that the operation data contains a non-empty list of marks.
  The actual redaction is handled by `Quire.Workers.SecureWorker`.
  """
  def apply(op_data, _context) do
    marks = op_data["marks"] || op_data[:marks] || []

    if is_list(marks) and marks != [] do
      {:ok, op_data}
    else
      {:error, :no_marks_provided}
    end
  end

  @doc """
  Computes the inverse of sec.redact_apply — reverts to the
  pre-redaction revision. Redaction is a destructive server-side transform.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end
end
