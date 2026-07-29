defmodule Quire.Engine.Error do
  @moduledoc """
  Structured engine error (§7.2).

  Replaces raw NIF error atoms with a map of typed fields that engines and
  their callers can pattern-match on.  The `message` field is user-facing;
  `detail` may contain diagnostics.

  ## Fields

    * `engine` — the engine module that raised (e.g. `Quire.Pdf`)
    * `operation` — the callback name (e.g. `:save`)
    * `code` — error category atom (`:nif`, `:invalid_argument`, `:timeout`,
      `:runtime`, `:function_clause`, `:unknown`)
    * `message` — user-facing string (never a raw NIF atom)
    * `detail` — developer-facing diagnostic (may include the original
      exception message)
  """

  defexception [:engine, :operation, :code, :message, :detail]

  @type code :: :nif | :invalid_argument | :timeout | :runtime | :function_clause | :unknown

  @type t :: %__MODULE__{
          engine: module(),
          operation: atom(),
          code: code(),
          message: String.t(),
          detail: String.t() | nil
        }

  @impl true
  def exception(fields) do
    struct!(__MODULE__, fields)
  end

  @impl true
  def message(%__MODULE__{message: msg}) when is_binary(msg), do: msg

  def message(%__MODULE__{code: code, detail: detail}) when is_binary(detail),
    do: "[#{code}] #{detail}"

  def message(%__MODULE__{code: code}), do: "[#{code}] Engine error"
end
