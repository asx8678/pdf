defmodule Quire.Editing.Ops.LinkAdd do
  @moduledoc """
  Validates and applies a `link.add` operation (§7.4, §9.5, T-093).

  A link is created either by dragging a rectangle on the canvas or by
  converting a selected text run. Either way the client pipes the geometry
  (`rect`, `page_index`) plus the chosen **action** from the Add Action modal;
  this op validates and normalises them, binds a stable `id`, and records the
  inverse so undo removes the link.

  ## Expected op_data fields

    * `"rect"` — `[x0, y0, x1, y1]` in PDF points (required)
    * `"page_index"` — zero-based page index (required)
    * `"source"` — `"rect"` (drag) or `"text"` (selected text) (optional)
    * `"action"` — the action map, `%{"type" => type, ...}` (required)

  All nine action types from §9.5 are accepted. The most safety-critical
  is `"javascript"`: its script is stored as opaque client data and is
  **never** executed or decoded server-side.
  """

  alias Quire.Editing.Ops.Link

  @doc """
  Validates and applies a `link.add` operation.

  Returns `{:ok, enriched_op_data}` where `op_data` has been normalised to
  string keys, given a generated `"id"` if absent, and validated. Returns
  `{:error, reason}` for a missing geometry or a malformed/forbidden action.
  """
  def apply(op_data, _context) do
    op = normalize_keys(op_data)

    with {:ok, _} <- require_op(op, ~w(page_index action)),
         {:ok, geometry} <- validate_geometry(op),
         {:ok, action} <- validate_action(op["action"]) do
      id = op["id"] || Ecto.UUID.generate()

      enriched =
        op
        |> Map.put("id", id)
        |> Map.put("rect", geometry)
        |> Map.put("action", action)
        |> Map.put_new("source", "rect")

      {:ok, enriched}
    end
  end

  @doc """
  Computes the inverse of `link.add`: undo removes the link that was added.

  Since the op catalogue has no standalone `link.delete` kind, the inverse is
  expressed with the `link.remove` directive (mirroring how `annot.add`
  inverts to `annot.delete`).
  """
  def invert(op, _context) do
    data = op_data(op)
    {:ok, %{kind: "link.remove", id: data["id"]}}
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
      {:error, "link.add requires: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_geometry(op) do
    case op["rect"] do
      [x0, y0, x1, y1] when is_number(x0) and is_number(y0) and is_number(x1) and
                              is_number(y1) ->
        case op["page_index"] do
          page when is_integer(page) and page >= 0 ->
            {:ok, [x0, y0, x1, y1]}

          _ ->
            {:error, "link.add requires a non-negative integer page_index"}
        end

      _ ->
        {:error, "link.add requires a valid rect [x0, y0, x1, y1]"}
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
        # Never evaluate. The code is opaque client data for the viewer's
        # PDFScriptingManager + pdf.sandbox.mjs. It is stored inert and
        # handed back verbatim to the client hook.
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
    # Atom-keyed action — normalise to string keys.
    validate_action(normalize_keys(action))
  end

  defp validate_action(nil), do: {:error, "link.add requires an action"}
  defp validate_action(_), do: {:error, "link.add requires an action"}
end