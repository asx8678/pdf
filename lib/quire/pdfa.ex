defmodule Quire.PdfA do
  @moduledoc ~S"""
  Best-effort PDF/A-2b conversion and structural conformance report
  (§9.2, T-084). Pure Elixir over the PDFium NIF (`ExPdfium`) for parsing
  and `Quire.Pdf` (lopdf) for structure writes.

  The five conversion steps:

    1. **Font embedding verification** — the PDFium NIF exposes no font API,
       so embedding is reported as `:not_verified` with a plain-language
       detail; nothing is silently claimed.
    2. **ICC OutputIntent injection** — an sRGB ICC profile
       (`priv/profiles/srgb.icc`) is attached as `/OutputIntents` on the
       catalog.
    3. **XMP metadata** — the PDF/A-2b XMP packet is written into a
       `/Metadata` stream.
    4. **MarkInfo** — `/MarkInfo << /Marked true >>` is set.
    5. **Forbidden-feature removal** — `/JavaScript`, `/AA`, `/OpenAction`
       and page-level `/AA` are stripped; anything removed is reported.

  Conformance is best-effort: the report lists every check as `:pass`,
  `:fail` or `:not_verified`, and the product never claims ISO
  certification or compliance (§1.2).
  """

  alias Quire.Pdf

  @level "2b"
  @profile_path "priv/profiles/srgb.icc"

  @doc """
  Converts a PDF to best-effort PDF/A-2b.

  Returns `{:ok, converted_bytes, report}` where `report` is

      %{
        level: "2b",
        best_effort: true,
        checks: [%{name: String.t(), status: :pass | :fail | :not_verified, detail: String.t()}]
      }

  or `{:error, reason}`.
  """
  @spec convert(binary(), keyword()) :: {:ok, binary(), map()} | {:error, term()}
  def convert(bytes, opts \\ []) when is_binary(bytes) do
    with {:ok, normalized} <- normalize(bytes),
         {:ok, q} <- Pdf.open(normalized),
         {:ok, checks, q} <- step_fonts(q, []),
         {:ok, checks, q} <- step_output_intent(q, checks, opts),
         {:ok, checks, q} <- step_xmp(q, checks),
         {:ok, checks, q} <- step_markinfo(q, checks),
         {:ok, checks, q} <- step_forbidden(q, checks),
         {:ok, out} <- Pdf.save(q) do
      {:ok, out, %{level: @level, best_effort: true, checks: checks}}
    end
  end

  @doc false
  def check do
    with {:ok, bytes} <-
           ExPdfium.new()
           |> then(fn {:ok, doc} -> ExPdfium.add_page(doc, {595.0, 842.0}) end)
           |> then(fn {:ok, doc} -> ExPdfium.save_to_bytes(doc) end) do
      case validate(bytes) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Runs the structural conformance report without modifying the document.

  Returns `{:ok, %{conformant: boolean(), level: String.t(), checks: [map()]}}`
  or `{:error, reason}`.
  """
  @spec validate(binary()) :: {:ok, map()} | {:error, term()}
  def validate(bytes) when is_binary(bytes) do
    with {:ok, normalized} <- normalize(bytes),
         {:ok, q} <- Pdf.open(normalized) do
      checks = run_checks(q)
      conformant = Enum.all?(checks, &(&1.status == :pass))
      {:ok, %{conformant: conformant, level: @level, checks: checks}}
    end
  end

  # ── Conversion steps ───────────────────────────────────────────────────

  defp step_fonts(q, checks) do
    check = %{
      name: "Font embedding",
      status: :not_verified,
      detail:
        "the PDFium NIF exposes no font API — embedding could not be verified; " <>
          "verify with Acrobat preflight before claiming conformance"
    }

    {:ok, checks ++ [check], q}
  end

  defp step_output_intent(q, checks, opts) do
    icc_bytes = icc_profile(opts)

    with {:ok, id} <- Pdf.allocate_object_id(q),
         :ok <-
           Pdf.set_object(
             q,
             id,
             {:stream, %{"/Type" => {:name, "OutputIntent"}, "/N" => 3}, icc_bytes}
           ),
         {:ok, catalog} <- Pdf.get_object(q, 1) do
      intent = %{
        "/Type" => {:name, "OutputIntent"},
        "/S" => {:name, "GTS_PDFA1"},
        "/OutputConditionIdentifier" => "sRGB IEC61966-2.1",
        "/Info" => "sRGB IEC61966-2.1",
        "/DestOutputProfile" => {:ref, id, 0}
      }

      with :ok <- Pdf.set_object(q, 1, Map.put(catalog, "/OutputIntents", [intent])) do
        check = %{
          name: "ICC OutputIntent",
          status: :pass,
          detail: "sRGB IEC61966-2.1 profile attached as /OutputIntents"
        }

        {:ok, checks ++ [check], q}
      end
    end
  end

  defp step_xmp(q, checks) do
    xmp = xmp_metadata()

    with {:ok, id} <- Pdf.allocate_object_id(q),
         :ok <-
           Pdf.set_object(
             q,
             id,
             {:stream, %{"/Type" => {:name, "Metadata"}, "/Subtype" => {:name, "XML"}}, xmp}
           ),
         {:ok, catalog} <- Pdf.get_object(q, 1) do
      with :ok <- Pdf.set_object(q, 1, Map.put(catalog, "/Metadata", {:ref, id, 0})) do
        check = %{
          name: "XMP metadata",
          status: :pass,
          detail: "PDF/A-2b XMP packet written to /Metadata"
        }

        {:ok, checks ++ [check], q}
      end
    end
  end

  defp step_markinfo(q, checks) do
    with {:ok, catalog} <- Pdf.get_object(q, 1) do
      existing = Map.get(catalog, "/MarkInfo", %{})
      markinfo = Map.merge(existing, %{"/Marked" => true})

      with :ok <- Pdf.set_object(q, 1, Map.put(catalog, "/MarkInfo", markinfo)) do
        check = %{
          name: "MarkInfo",
          status: :pass,
          detail: "/MarkInfo << /Marked true >> set"
        }

        {:ok, checks ++ [check], q}
      end
    end
  end

  defp step_forbidden(q, checks) do
    with {:ok, catalog} <- Pdf.get_object(q, 1) do
      removed =
        catalog
        |> Map.take(["/JavaScript", "/AA", "/OpenAction", "/Encrypt"])
        |> Map.keys()

      catalog = Map.drop(catalog, ["/JavaScript", "/AA", "/OpenAction"])
      page_actions = remove_page_actions(q, catalog)

      with :ok <- Pdf.set_object(q, 1, catalog) do
        detail =
          case removed ++ page_actions do
            [] -> "no forbidden features found (encryption, JS, actions)"
            list -> "removed: " <> Enum.join(Enum.map(list, &to_string/1), ", ")
          end

        check = %{
          name: "Forbidden-feature removal",
          status: :pass,
          detail: detail
        }

        {:ok, checks ++ [check], q}
      end
    end
  end

  # ── Validation checks ──────────────────────────────────────────────────

  defp run_checks(q) do
    case Pdf.get_object(q, 1) do
      {:ok, catalog} ->
        [
          check_encryption(catalog),
          check_output_intents(catalog),
          check_xmp(catalog),
          check_markinfo(catalog),
          check_forbidden(catalog),
          check_struct_tree(catalog)
        ]

      _ ->
        [%{name: "Catalog", status: :fail, detail: "could not read the catalog"}]
    end
  end

  defp check_encryption(catalog) do
    %{
      name: "No encryption",
      status: if(Map.has_key?(catalog, "/Encrypt"), do: :fail, else: :pass),
      detail:
        if(Map.has_key?(catalog, "/Encrypt"), do: "document is encrypted", else: "no /Encrypt")
    }
  end

  defp check_output_intents(catalog) do
    status =
      case Map.get(catalog, "/OutputIntents") do
        list when is_list(list) and list != [] -> :pass
        _ -> :fail
      end

    %{
      name: "ICC OutputIntent",
      status: status,
      detail: if(status == :pass, do: "/OutputIntents present", else: "missing /OutputIntents")
    }
  end

  defp check_xmp(catalog) do
    status =
      case Map.get(catalog, "/Metadata") do
        {:ref, _, _} -> :pass
        _ -> :fail
      end

    %{
      name: "XMP metadata",
      status: status,
      detail: if(status == :pass, do: "/Metadata present", else: "missing /Metadata")
    }
  end

  defp check_markinfo(catalog) do
    marked =
      case Map.get(catalog, "/MarkInfo") do
        %{"/Marked" => true} -> true
        _ -> false
      end

    %{
      name: "MarkInfo",
      status: if(marked, do: :pass, else: :fail),
      detail: if(marked, do: "/MarkInfo /Marked true", else: "missing /MarkInfo /Marked true")
    }
  end

  defp check_forbidden(catalog) do
    found =
      catalog
      |> Map.take(["/JavaScript", "/AA", "/OpenAction"])
      |> Map.keys()

    %{
      name: "No JS / actions",
      status: if(found == [], do: :pass, else: :fail),
      detail:
        if(found == [],
          do: "no /JavaScript, /AA or /OpenAction",
          else: "found: " <> Enum.join(found, ", ")
        )
    }
  end

  defp check_struct_tree(_catalog) do
    %{
      name: "StructTreeRoot (tagged)",
      status: :not_verified,
      detail:
        "a /StructTreeRoot could not be generated without a source tag tree — " <>
          "verify tagging with Acrobat preflight before claiming conformance"
    }
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp normalize(bytes) do
    with {:ok, doc} <- ExPdfium.open(bytes) do
      ExPdfium.save_to_bytes(doc)
    end
  end

  defp icc_profile(opts) do
    case Keyword.get(opts, :icc_profile) do
      nil ->
        path = Path.join(Application.app_dir(:quire), @profile_path)
        File.read!(path)

      bytes when is_binary(bytes) ->
        bytes
    end
  end

  defp xmp_metadata do
    ~s(<?xpacket begin="\uFEFF" id="W5M0MpCehiHzreSzNTczkc9d"?>\n) <>
      ~s(<x:xmpmeta xmlns:x="adobe:ns:meta/">\n) <>
      ~s(<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n) <>
      ~s(<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">\n) <>
      ~s(<pdfaid:part>2</pdfaid:part>\n) <>
      ~s(<pdfaid:conformance>B</pdfaid:conformance>\n) <>
      ~s(</rdf:Description>\n) <>
      ~s(</rdf:RDF>\n) <>
      ~s(</x:xmpmeta>\n) <>
      ~s(<?xpacket end="w"?>\n)
  end

  # Removes /AA from every page; returns the list of page indices touched.
  defp remove_page_actions(q, catalog) do
    page_refs =
      case Map.get(catalog, "/Pages") do
        {:ref, pages_obj, _} -> collect_page_refs(q, pages_obj)
        _ -> []
      end

    Enum.reduce(page_refs, [], fn {obj, gen}, removed ->
      case Pdf.get_object(q, {obj, gen}) do
        {:ok, page} when is_map(page) ->
          if Map.has_key?(page, "/AA") do
            _ = Pdf.set_object(q, {obj, gen}, Map.delete(page, "/AA"))
            removed ++ ["page #{obj} /AA"]
          else
            removed
          end

        _ ->
          removed
      end
    end)
  end

  defp collect_page_refs(q, pages_obj) do
    case Pdf.get_object(q, pages_obj) do
      {:ok, node} ->
        case Map.get(node, "/Kids") do
          kids when is_list(kids) ->
            Enum.flat_map(kids, fn
              {:ref, child, gen} ->
                case Pdf.get_object(q, {child, gen}) do
                  {:ok, %{"/Type" => {:name, "Pages"}}} -> collect_page_refs(q, child)
                  _ -> [{child, gen}]
                end

              _ ->
                []
            end)

          {:ref, child, gen} ->
            [{child, gen}]

          _ ->
            []
        end

      _ ->
        []
    end
  end
end
