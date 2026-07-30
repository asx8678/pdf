defmodule Quire.FormData.FDF do
  @moduledoc false

  def decode(fdf_binary) when is_binary(fdf_binary) do
    pairs = extract_field_pairs(fdf_binary)
    {:ok, Map.new(pairs)}
  end

  def encode(data) when is_map(data) do
    fields_body =
      Enum.map(data, fn {name, value} ->
        "  /T (#{escape_pdf_str(name)}) /V (#{escape_pdf_str(to_string(value))})\n"
      end)

    fdf = [
      "%FDF-1.2\n",
      "1 0 obj\n",
      "<< /FDF << /Fields [\n",
      fields_body,
      "] >> >>\n",
      "endobj\n",
      "trailer\n",
      "<< /Root 1 0 R >>\n",
      "%%EOF\n"
    ]

    {:ok, IO.iodata_to_binary(fdf)}
  end

  defp escape_pdf_str(s) do
    s
    |> :binary.replace("\\", "\\\\", [:global])
    |> :binary.replace("(", "\\(", [:global])
    |> :binary.replace(")", "\\)", [:global])
    |> :binary.replace("\n", "\\n", [:global])
    |> :binary.replace("\r", "\\r", [:global])
  end

  # ── Decoder ─────────────────────────────

  defp extract_field_pairs(bin) do
    extract_field_pairs(bin, 0, [])
  end

  defp extract_field_pairs(bin, from, acc) when from < byte_size(bin) do
    case :binary.match(bin, "/T (", [{:scope, {from, byte_size(bin) - from}}]) do
      {pos, _} ->
        content = :binary.part(bin, pos + 4, byte_size(bin) - pos - 4)
        name = parse_pdf_string(content, [], 1)

        if name != nil do
          {name_text, after_name} = name
          value = parse_next_value(after_name)

          if value != nil do
            {val_text, after_val} = value
            new_from = byte_size(bin) - byte_size(after_val)
            extract_field_pairs(bin, new_from, [{name_text, val_text} | acc])
          else
            Enum.reverse(acc)
          end
        else
          Enum.reverse(acc)
        end

      :nomatch ->
        Enum.reverse(acc)
    end
  end

  defp extract_field_pairs(_bin, _from, acc), do: Enum.reverse(acc)

  # Parse content of a PDF literal string after the opening (.
  # Handles escapes: \(, \), \\, \n, \r, \t, and general \c.
  # Returns {decoded_string, rest_of_binary} or nil on truncation.
  defp parse_pdf_string(<<>>, _acc, _depth), do: nil

  defp parse_pdf_string(<<"\\(", rest::binary>>, acc, depth) do
    parse_pdf_string(rest, [?( | acc], depth)
  end

  defp parse_pdf_string(<<"\\)", rest::binary>>, acc, depth) do
    parse_pdf_string(rest, [?) | acc], depth)
  end

  defp parse_pdf_string(<<"\\\\", rest::binary>>, acc, depth) do
    parse_pdf_string(rest, [?\\ | acc], depth)
  end

  defp parse_pdf_string(<<"\\n", rest::binary>>, acc, depth) do
    parse_pdf_string(rest, [?\n | acc], depth)
  end

  defp parse_pdf_string(<<"\\r", rest::binary>>, acc, depth) do
    parse_pdf_string(rest, [?\r | acc], depth)
  end

  defp parse_pdf_string(<<"\\t", rest::binary>>, acc, depth) do
    parse_pdf_string(rest, [?\t | acc], depth)
  end

  defp parse_pdf_string(<<"\\", c::8, rest::binary>>, acc, depth) do
    parse_pdf_string(rest, [c | acc], depth)
  end

  defp parse_pdf_string(<<"(", rest::binary>>, acc, depth) do
    parse_pdf_string(rest, acc, depth + 1)
  end

  defp parse_pdf_string(<<")", rest::binary>>, acc, 1) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp parse_pdf_string(<<")", rest::binary>>, acc, depth) do
    parse_pdf_string(rest, acc, depth - 1)
  end

  defp parse_pdf_string(<<c::8, rest::binary>>, acc, depth) do
    parse_pdf_string(rest, [c | acc], depth)
  end

  # Find /V (value) or /V /Name after previous field.
  defp parse_next_value(bin) do
    case :binary.match(bin, "/V (", [{:scope, {0, byte_size(bin)}}]) do
      {pos, _} ->
        content = :binary.part(bin, pos + 4, byte_size(bin) - pos - 4)
        parse_pdf_string(content, [], 1)

      :nomatch ->
        case :binary.match(bin, "/V /", [{:scope, {0, byte_size(bin)}}]) do
          {pos, _} ->
            rest = :binary.part(bin, pos + 4, byte_size(bin) - pos - 4)
            name = rest |> String.split([" ", "\n", "\r", "\t", ">>", "]"], parts: 2) |> hd()
            after_val = :binary.part(rest, byte_size(name), byte_size(rest) - byte_size(name))
            {name, after_val}

          :nomatch ->
            nil
        end
    end
  end
end

defmodule Quire.FormData.XFDF do
  @moduledoc false

  def decode(xfdf_binary) when is_binary(xfdf_binary) do
    fields = extract_field_values(xfdf_binary)
    {:ok, Map.new(fields)}
  end

  def encode(data) when is_map(data) do
    fields_body =
      Enum.map(data, fn {name, value} ->
        ~s'  <field name="#{xml_escape(name)}"><value>#{xml_escape(to_string(value))}</value></field>\n'
      end)

    xml = [
      ~s'<?xml version="1.0" encoding="UTF-8"?>\n',
      ~s'<xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">\n',
      "<fields>\n",
      fields_body,
      "</fields>\n",
      "</xfdf>\n"
    ]

    {:ok, IO.iodata_to_binary(xml)}
  end

  defp extract_field_values(xml) do
    Regex.scan(~r/<field\s+name="([^"]*)"[^>]*>.*?<value>([^<]*)<\/value>.*?<\/field>/s, xml)
    |> Enum.map(fn [_, name, value] -> {name, xml_unescape(value)} end)
  end

  defp xml_escape(s) do
    s
    |> :binary.replace("&", "&amp;", [:global])
    |> :binary.replace("<", "&lt;", [:global])
    |> :binary.replace(">", "&gt;", [:global])
    |> :binary.replace(~s("), "&quot;", [:global])
    |> :binary.replace("'", "&apos;", [:global])
  end

  defp xml_unescape(s) do
    s
    |> :binary.replace("&quot;", ~s("), [:global])
    |> :binary.replace("&apos;", "'", [:global])
    |> :binary.replace("&gt;", ">", [:global])
    |> :binary.replace("&lt;", "<", [:global])
    |> :binary.replace("&amp;", "&", [:global])
  end
end

defmodule Quire.FormData do
  @moduledoc """
  Form data import, export, and PDF field value writing.
  """

  alias Quire.Pdf
  alias Quire.Pdf.AcroForm

  @doc """
  Read form field values from a PDF binary.
  Returns `{:ok, fields}` where each field has `:name`, `:value`, `:type`,
  `:page`, `:bounds`, `:checked`, `:read_only`, `:required`.
  """
  @spec read(binary()) :: {:ok, [map()]} | {:error, atom()}
  def read(pdf_binary) when is_binary(pdf_binary) do
    with {:ok, doc} <- ExPdfium.open_blob(pdf_binary) do
      ExPdfium.form_fields(doc)
    end
  end

  @doc """
  Read field values as flat `%{name => value}` map. Nil values omitted.
  """
  @spec read_values(binary()) :: {:ok, map()} | {:error, atom()}
  def read_values(pdf_binary) when is_binary(pdf_binary) do
    with {:ok, fields} <- read(pdf_binary) do
      {:ok,
       fields
       |> Enum.filter(&(not is_nil(&1.value)))
       |> Map.new(&{&1.name, &1.value})}
    end
  end

  @doc """
  Read default field values from a PDF by walking the AcroForm field tree and
  collecting `/DV` entries.

  Returns `{:ok, %{name => default_value}}`. Fields without a `/DV` default are
  omitted from the map.
  """
  @spec read_defaults(binary()) :: {:ok, map()} | {:error, term()}
  def read_defaults(pdf_binary) when is_binary(pdf_binary) do
    with {:ok, qdoc} <- Pdf.open(pdf_binary) do
      defaults = collect_defaults(qdoc)
      {:ok, defaults}
    end
  end

  @doc """
  Reset all form fields to their default values.

  Equivalent to `read_defaults/1` + `write/3`, wrapped in a single call.
  Pass `flatten: true` to flatten after resetting.

  Returns `{:ok, updated_pdf_binary}`.
  """
  @spec reset(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def reset(pdf_binary, opts \\ []) when is_binary(pdf_binary) do
    with {:ok, defaults} <- read_defaults(pdf_binary) do
      if defaults == %{} do
        {:ok, pdf_binary}
      else
        write(pdf_binary, defaults, opts)
      end
    end
  end

  @doc """
  Write form field values to a PDF and regenerate appearances.

  Options:
    * `:flatten` — if `true`, flatten document after writing (default `false`).

  Returns `{:ok, updated_pdf_binary}`.
  """
  @spec write(binary(), map() | keyword()) :: {:ok, binary()} | {:error, atom()}
  def write(pdf_binary, values, opts \\ []) when is_binary(pdf_binary) do
    flatten? = Keyword.get(opts, :flatten, false)

    values_map =
      case values do
        list when is_list(list) -> Map.new(list, &{&1.name, &1.value})
        map when is_map(map) -> map
      end

    with {:ok, qdoc} <- Pdf.open(pdf_binary),
         :ok <- set_field_values(qdoc, values_map),
         :ok <- AcroForm.generate_appearances(qdoc),
         {:ok, modified_bytes} <- Pdf.save(qdoc) do
      if flatten? do
        flatten(modified_bytes)
      else
        {:ok, modified_bytes}
      end
    end
  end

  @doc """
  Flatten a PDF — bake form appearances into page content.
  """
  @spec flatten(binary()) :: {:ok, binary()} | {:error, atom()}
  def flatten(pdf_binary) when is_binary(pdf_binary) do
    with {:ok, doc} <- ExPdfium.open_blob(pdf_binary),
         {:ok, _} <- ExPdfium.flatten(doc),
         {:ok, bytes} <- ExPdfium.save_to_bytes(doc) do
      {:ok, bytes}
    end
  end

  @doc """
  Import form data from :fdf, :xfdf, :json, or :csv into `%{name => value}`.
  """
  @spec import(binary(), :fdf | :xfdf | :json | :csv) :: {:ok, map()} | {:error, term()}
  def import(data, :fdf), do: __MODULE__.FDF.decode(data)
  def import(data, :xfdf), do: __MODULE__.XFDF.decode(data)
  def import(data, :json), do: decode_json(data)
  def import(data, :csv), do: decode_csv(data)

  @doc """
  Export a `%{name => value}` map to the given format.
  """
  @spec export(map(), :fdf | :xfdf | :json | :csv) :: {:ok, binary()} | {:error, term()}
  def export(data, :fdf), do: __MODULE__.FDF.encode(data)
  def export(data, :xfdf), do: __MODULE__.XFDF.encode(data)
  def export(data, :json), do: encode_json(data)
  def export(data, :csv), do: encode_csv(data)

  # ── PDF field value writer ────────────────

  defp set_field_values(qdoc, values) do
    with {:ok, field_refs} <- fetch_field_refs(qdoc) do
      walk_and_set(qdoc, field_refs, values)
    end
  end

  defp fetch_field_refs(qdoc) do
    with {:ok, catalog} <- Pdf.catalog(qdoc) do
      case catalog do
        %{"/AcroForm" => {:ref, af_num, af_gen}} ->
          with {:ok, af} <- Pdf.get_object(qdoc, {af_num, af_gen}) do
            fields = Map.get(af, "/Fields", []) |> List.wrap()
            {:ok, fields}
          end

        _ ->
          {:ok, []}
      end
    end
  end

  defp collect_defaults(qdoc) do
    with {:ok, field_refs} <- fetch_field_refs(qdoc) do
      walk_defaults(qdoc, field_refs, %{})
    end
  end

  defp walk_defaults(_qdoc, [], acc), do: acc

  defp walk_defaults(qdoc, [{:ref, num, gen} | rest], acc) do
    case Pdf.get_object(qdoc, {num, gen}) do
      {:ok, field} when is_map(field) ->
        kids = Map.get(field, "/Kids", [])
        has_ft = Map.has_key?(field, "/FT")

        acc =
          if has_ft and Map.has_key?(field, "/T") and Map.has_key?(field, "/DV") do
            name = Map.get(field, "/T")
            dv = field["/DV"]
            value = normalize_default(dv)
            if value != nil, do: Map.put(acc, name, value), else: acc
          else
            acc
          end

        walk_defaults(qdoc, List.wrap(kids) ++ rest, acc)

      _ ->
        walk_defaults(qdoc, rest, acc)
    end
  end

  defp walk_defaults(qdoc, [_non_ref | rest], acc) do
    walk_defaults(qdoc, rest, acc)
  end

  defp normalize_default(nil), do: nil
  defp normalize_default(b) when is_binary(b), do: b
  defp normalize_default(true), do: "Yes"
  defp normalize_default(false), do: "Off"
  defp normalize_default({:name, n}), do: n
  defp normalize_default(_), do: nil

  defp walk_and_set(_qdoc, [], _values), do: :ok

  defp walk_and_set(qdoc, [{:ref, num, gen} | rest], values) do
    case Pdf.get_object(qdoc, {num, gen}) do
      {:ok, field} when is_map(field) ->
        kids = Map.get(field, "/Kids", [])

        result =
          if Map.has_key?(field, "/FT") and Map.has_key?(field, "/T") do
            name = Map.get(field, "/T")

            if Map.has_key?(values, name) do
              Pdf.set_object(qdoc, {num, gen}, Map.put(field, "/V", values[name]))
            else
              :ok
            end
          else
            :ok
          end

        case result do
          :ok -> walk_and_set(qdoc, List.wrap(kids) ++ rest, values)
          {:error, _} = err -> err
        end

      _ ->
        walk_and_set(qdoc, rest, values)
    end
  end

  defp walk_and_set(qdoc, [_non_ref | rest], values) do
    walk_and_set(qdoc, rest, values)
  end

  # ── JSON ──────────────────────────────────

  defp decode_json(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :expected_object}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp encode_json(data) when is_map(data) do
    {:ok, Jason.encode!(data)}
  end

  # ── CSV ───────────────────────────────────

  defp decode_csv(data) when is_binary(data) do
    lines = String.split(data, ["\n", "\r\n"], trim: true)

    case lines do
      [header, values | _] ->
        names = parse_csv_line(header)
        vals = parse_csv_line(values)
        pairs = Enum.zip(names, vals) |> Enum.filter(fn {_n, v} -> v != "" end)
        {:ok, Map.new(pairs)}

      _ ->
        {:error, :unexpected_format}
    end
  end

  defp encode_csv(data) when is_map(data) do
    names = Map.keys(data)
    vals = Map.values(data)
    {:ok, encode_csv_line(names) <> "\n" <> encode_csv_line(vals) <> "\n"}
  end

  defp parse_csv_line(line) do
    line |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp encode_csv_line(items) when is_list(items) do
    items
    |> Enum.map(fn
      item when is_binary(item) -> item
      item -> to_string(item)
    end)
    |> Enum.join(", ")
  end
end
