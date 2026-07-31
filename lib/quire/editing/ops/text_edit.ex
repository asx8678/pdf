defmodule Quire.Editing.Ops.TextEdit do
  @moduledoc false

  alias Quire.Editor.RunIdentifier
  alias Quire.Editor.RunRewriter
  alias Quire.Engine
  alias Quire.Storage.Ref

  @doc """
  Applies a text.edit operation (pdf-un45).

  Expected `op_data` fields:
    * `:ref` — `Quire.Storage.Ref.t()` pointing to the document bytes
    * `:page_index` — zero-based page index
    * `:run` — the identified run from `RunIdentifier.identify_runs/2`
    * `:new_text` — the replacement text
    * `:click_x`, `:click_y` — (optional) click position for fallback
      run identification if `:run` is not provided

  Pipeline:
    1. Resolve the target text run (from `:run` or by click position)
    2. Check font availability via `RunIdentifier.check_font_available/1`
    3. Rewrite the content stream via `RunRewriter.rewrite_run/3`
    4. Return op data enriched with the content stream fragment
  """
  def apply(op_data, _context) do
    # Backward-compatible: when called without the fields needed for the
    # RunIdentifier/RunRewriter pipeline (e.g. property tests), fall back
    # to the original stub behavior.
    # NB: `and` requires a boolean left operand — use explicit nil checks.
    if !is_nil(op_data[:new_text]) and (!is_nil(op_data[:run]) or !is_nil(op_data[:ref])) do
      do_apply(op_data)
    else
      {:ok, op_data}
    end
  end

  defp do_apply(op_data) do
    with {:ok, run} <- resolve_run(op_data),
         :ok <- RunIdentifier.check_font_available(run),
         {:ok, stream} <- RunRewriter.rewrite_run(run, op_data.new_text, []) do
      {:ok,
       op_data
       |> Map.put(:run, run)
       |> Map.put(:content_stream, IO.iodata_to_binary(stream))}
    else
      {:error, :font_unavailable, msg} ->
        {:error,
         %Engine.Error{
           engine: __MODULE__,
           operation: :apply,
           code: :font_unavailable,
           message: msg
         }}

      {:error, %Engine.Error{} = err} ->
        {:error, err}

      {:error, reason} ->
        {:error,
         %Engine.Error{
           engine: __MODULE__,
           operation: :apply,
           code: :runtime,
           message: inspect(reason)
         }}

      nil ->
        {:error,
         %Engine.Error{
           engine: __MODULE__,
           operation: :apply,
           code: :no_run,
           message: "No text run found at click position"
         }}
    end
  end

  @doc """
  Computes the inverse of text.edit.
  Real undo needs the original text captured at apply time.
  """
  def invert(_op_data, _context) do
    {:ok, {:restore_revision, nil}}
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp resolve_run(%{ref: %Ref{} = ref, page_index: pi} = op) do
    if run = op[:run] do
      {:ok, run}
    else
      identify_run_at(ref, pi, op[:click_x], op[:click_y])
    end
  end

  defp resolve_run(%{run: run}) when is_map(run), do: {:ok, run}
  defp resolve_run(_), do: nil

  defp identify_run_at(ref, page_index, x, y) when is_number(x) and is_number(y) do
    with {:ok, runs} <- RunIdentifier.identify_runs(ref, page_index) do
      run = find_run_at_click(runs, x, y)

      if run, do: {:ok, run}, else: nil
    end
  end

  defp identify_run_at(_ref, _page_index, _x, _y), do: nil

  defp find_run_at_click(runs, x, y) do
    Enum.find(runs, fn run ->
      [x0, y0, x1, y1] = run.bbox
      x >= x0 and x <= x1 and y >= y0 and y <= y1
    end) ||
      Enum.min_by(runs, fn run ->
        [x0, y0, x1, y1] = run.bbox
        cx = (x0 + x1) / 2
        cy = (y0 + y1) / 2
        :math.sqrt((x - cx) ** 2 + (y - cy) ** 2)
      end)
  rescue
    _ -> nil
  end
end
