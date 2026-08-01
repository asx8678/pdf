defmodule Quire.Editing.Ops.LinkEdit do
  @moduledoc """
  Validates and applies a `link.edit` operation (§7.4, §9.5, T-093).

  Editing an existing link replaces its action (opened from the Add Action
  modal on an existing link). The inverse restores the **prior link action
  state**.

  ## Expected op_data fields

    * `"id"` — the link id to edit (required)
    * `"action"` — the new action map, `%{"type" => type, ...}` (required)
    * `"previous_action"` — the action the link had before this edit. The
      client supplies it (it already rendered optimistically); the op also
      accepts it directly so undo can restore the prior state.

  The same nine action types and the same JavaScript / URL-scheme safety
  rules as `link.add` apply.
  """

  alias Quire.Editing.Ops.Link

  @doc """
  Validates and applies a `link.edit` operation.

  Normalises keys, requires a target `id` and a valid action, and tags the
  result with `"previous_action"` so the inverse can restore the prior state.
  Returns `{:ok, enriched_op_data}` or `{:error, reason}`.
  """
  def apply(op_data, _context) do
    op = normalize_keys(op_data)

    with {:ok, _} <- require_op(op, ~w(id action)),
         {:ok, action} <- validate_action(op["action"]) do
      enriched =
        op
        |> Map.put("action", action)
        |> Map.put_new("previous_action", op["previous_action"])

      {:ok, enriched}
    end
  end

  @doc """
  Computes the inverse of `link.edit`: undo restores the prior link action.

  The inverse is a `link.edit` carrying `id` and the captured
  `"previous_action"`.
  """
  def invert(op, _context) do
    data = op_data(op)
    previous = data["previous_action"]

    if is_map(previous) do
      {:ok, %{kind: "link.edit", id: data["id"], next_action: previous, restore: true}}
    else
      {:ok, %{kind: "link.edit", id: data["id"], restore: true}}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp op_data(%{"data" => data}) when is_map(data), do: normalize_keys(data)
  defp op_data(%{data: data}) when is_map(data), do: normalize_keys(data)
  defp op_data(op) when is_map(op), do: normalize_keys(op)

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp require_op(op, fields) do
    missing = Enum.filter(fields, fn f -> is_nil(op[f]) or op[f] == "" end)

    if missing == [] do
      {:ok, op}
    else
      {:error, "link.edit requires: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_action(%{"type" => type} = action) when is_binary(type) do
    type = String.downcase(type)

    cond do
      type not in Link.all_types() ->
        {:error, "Unknown link action type: #{type}"}

      not Link.valid_action?(Map.put(action, "type", type)) ->
        {:error, "Invalid or incomplete action for type: #{type}"}

      type == "javascript" ->
        {:ok,
         action
         |> Map.put("type", "javascript")
         |> Map.put("code", Link.value_or_nil(action["code"] || action["javascript"]))
         |> Map.put("server_eval", false)}

      true ->
        {:ok, Map.put(action, "type", type)}
    end
  end

  defp validate_action(%{} = action) do
    validate_action(normalize_keys(action))
  end

  defp validate_action(nil), do: {:error, "link.edit requires an action"}
  defp validate_action(_), do: {:error, "link.edit requires an action"}
end