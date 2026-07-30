defmodule Quire.Editing.Operation do
  @moduledoc """
  An edit operation in the journal (§7.4).

  Fields:
    * `kind` — string from the operation catalogue (e.g. "annot.add")
    * `data` — map of operation-specific parameters
    * `inverse` — sufficient payload to undo without consulting anything else;
                 server-side ops use `{:restore_revision, revision_id}`
    * `metadata` — `%{applied_by: caller_pid, applied_at: DateTime.utc_now()}`
    * `timestamp` — `System.monotonic_time()` for coalescing comparisons
  """

  defstruct [:kind, :data, :inverse, :metadata, :timestamp]

  @type kind :: String.t()
  @type t :: %__MODULE__{
          kind: kind(),
          data: map(),
          inverse: map() | {:restore_revision, String.t()},
          metadata: map(),
          timestamp: integer()
        }

  @doc """
  Returns the Operation module for a given kind string.
  """
  def module_for_kind(kind) do
    parts = String.split(kind, ".") |> Enum.map(&Macro.camelize/1)
    mod_name = Enum.join(parts, "")
    {:ok, Module.concat(Quire.Editing.Ops, mod_name)}
  rescue
    _ -> {:error, :unknown_kind}
  end
end
