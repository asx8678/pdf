defmodule Quire.Editing.Ops.Link do
  @moduledoc """
  Shared helpers for the `link.add` / `link.edit` operations (§7.4, T-093).

  A PDF link annotation carries an action (PDF `/Action` dictionary). This
  module owns the action-type catalogue, the URL scheme allowlist, and the
  validation shared by both link ops.

  ## Action types

  The nine action types from §9.5's **Add Action** modal:

    * Card grid (`card_types/0`): `open`, `open_file`, `page`
    * Overflow (`overflow_types/0`): `goto_destination`, `menu_item`,
      `submit_form`, `reset_form`, `show_hide_field`, `javascript`

  ## Security

  * **Run JavaScript is OFF by default** and is **never evaluated
    server-side**. In link op payloads the script is carried only as opaque
    client data — a token to hand to pdf.js's `PDFScriptingManager` +
    `pdf.sandbox.mjs` in the viewer. Nothing here ever evaluates it.
  * URL fields are restricted to an explicit scheme allowlist so a link can
    never carry `javascript:`-style executable content into the document.
  """

  # The msb action-type catalogue. Strings are stored in op data and sent
  # from the modal form.
  @card_types ~w(open open_file page)
  @overflow_types ~w(goto_destination menu_item submit_form reset_form show_hide_field javascript)
  @all_types @card_types ++ @overflow_types

  @doc "The three card types shown in the grid."
  def card_types, do: @card_types

  @doc "The six overflow types behind the ⋮ dropdown."
  def overflow_types, do: @overflow_types

  @doc "All nine action types in order."
  def all_types, do: @all_types

  @doc """
  URL schemes allowed for the **Open web page** action.
  `javascript:` is deliberately excluded.
  """
  def url_schemes, do: ~w(http https mailto tel)

  @doc "Returns `true` when `str` uses an allowed URL scheme."
  def allowed_url?(str) when is_binary(str) do
    url_scheme(str) in url_schemes()
  end

  def allowed_url?(_), do: false

  # `mailto:`, `http://`, `https://`, `tel:`.
  defp url_scheme(str) do
    case String.split(str, ":") do
      [scheme | _] when scheme != str -> String.downcase(scheme)
      _ -> ""
    end
  end

  @doc """
  Validates a URL/action.

  Empty strings (`:url_blank`) and disallowed schemes (`:disallowed_scheme`)
  are rejected.
  """
  def validate_url(url) do
    cond do
      not is_binary(url) or url == "" -> {:error, :url_blank}
      not allowed_url?(url) -> {:error, :disallowed_scheme}
      true -> {:ok, url}
    end
  end

  @doc """
  Returns `true` when an action map is complete/valid for its `type`, i.e.
  the type is known and its required field is present and non-empty.

  Used to gate the modal **Apply** button until the type-specific form is
  valid. Unknown types are never valid.
  """
  def valid_action?(%{"type" => type} = action) when is_binary(type) do
    type in @all_types and required_field_ok?(type, action)
  end

  def valid_action?(%{type: type} = action) when is_binary(type) do
    valid_action?(Map.put(stringify_keys(action), "type", type))
  end

  def valid_action?(_), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp required_field_ok?(type, action) do
    case type do
      # Open web page — URL required + allowlisted
      "open" ->
        case validate_url(field(action, "url")) do
          {:ok, _} -> true
          _ -> false
        end

      # Open file — a selected Ref / filename is required
      "open_file" ->
        ref = field(action, "ref") || field(action, "file_name") || field(action, "file")
        filled?(ref)

      # Go to page — a positive page number, or a named destination
      "page" ->
        page = string_to_int(field(action, "page_number"))
        (page != nil and page >= 1) or filled?(field(action, "named_destination"))

      # Named destination
      "goto_destination" ->
        filled?(field(action, "name"))

      # Execute a menu item — a named command
      "menu_item" ->
        filled?(field(action, "name"))

      # Submit form — a target URL
      "submit_form" ->
        filled?(field(action, "url"))

      # Reset form — no required params
      "reset_form" ->
        true

      # Show/hide field — a field name
      "show_hide_field" ->
        filled?(field(action, "field"))

      # Run JavaScript — a script body is required. Whether JS is enabled at
      # all lives in the LiveView (off by default) — not here.
      "javascript" ->
        filled?(field(action, "code")) or filled?(field(action, "javascript"))

      _ ->
        false
    end
  end

  @doc """
  Extracts a field from an action map that may be string- or atom-keyed.
  """
  def field(action, key) when is_map(action) do
    string_key = to_string(key)
    Map.get(action, string_key) || Map.get(action, existing_atom(string_key))
  end

  def field(_action, _key), do: nil

  # Reads an atom key only if the atom already exists (never creates new
  # atoms from user-ish data).
  defp existing_atom(string_key) do
    try do
      String.to_existing_atom(string_key)
    rescue
      ArgumentError -> nil
    end
  end

  @doc "String value or nil for empty."
  def value_or_nil(v) when is_binary(v), do: if(v == "", do: nil, else: v)
  def value_or_nil(nil), do: nil
  def value_or_nil(v), do: v

  defp filled?(nil), do: false
  defp filled?(v) when is_binary(v), do: v != ""
  defp filled?(_), do: true

  defp string_to_int(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp string_to_int(nil), do: nil
  defp string_to_int(int) when is_integer(int), do: int
  defp string_to_int(_), do: nil
end