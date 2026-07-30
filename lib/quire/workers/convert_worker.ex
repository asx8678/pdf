defmodule Quire.Workers.ConvertWorker do
  @moduledoc ~S"""
  Oban worker for HTML/URL to PDF conversion via chromic_pdf (§T-072).

  Two source types — `html` (a self-contained HTML string) and `url` (a
  remote URL fetched and printed through the SSRF guard) — both producing
  a new revision of an existing document.

  ## Queue

  Runs on the `:convert` queue, serialised (concurrency 1, §7.2).

  ## Job args

      %{
        "source_type"    => "html",                     # required: "html" | "url"
        "html"           => "<!DOCTYPE html>...",       # required for html
        "url"            => "https://example.com",      # required for url
        "doc_id"         => doc_id,                     # required
        "revision_id"    => revision_id,                # required (base revision)
        "operation_id"   => op_id,                      # optional, for progress
        "filename"       => "converted.pdf",            # optional
        "page_size"      => "A4",                       # optional — atom name or {w,h} tuple
        "landscape"      => false,                      # optional
        "background"     => true,                       # optional — print background graphics
        "header"         => "<span>My Header</span>",    # optional — header HTML template
        "footer"         => "<span>Page %p</span>",     # optional — footer HTML template
        "wait_for"       => %{selector: "#ready", attribute: "data-loaded"},  # optional
        "margins"        => %{top: 0.4, bottom: 0.4, left: 0.4, right: 0.4}, # optional, inches
        "disable_scripts"   => false,                   # optional
        "offline"           => true                     # optional
      }

  ## Persistence

  Follows the `OcrWorker` pattern: convert → `Storage.put` →
  `Documents.create_revision` with a `source` map referencing the
  stored blob.
  """

  use Oban.Worker,
    queue: :convert,
    unique: [period: 60, fields: [:worker, :args]],
    max_attempts: 2

  use Quire.Workers.Base

  alias Quire.Repo
  alias Quire.Storage
  alias Quire.Documents
  alias Quire.Documents.Document
  alias Quire.SsrfGuard

  # ── Oban callback ──────────────────────────────────────────────────────

  @impl true
  def perform(%Oban.Job{args: args}) do
    source_type = args["source_type"]
    doc_id = args["doc_id"]

    result =
      case source_type do
        "html" -> convert_html(args)
        "url" -> convert_url(args)
        other -> {:error, "Unknown source_type '#{other}'. Expected 'html' or 'url'."}
      end

    case result do
      {:ok, pdf_binary} ->
        persist_result(pdf_binary, args)
        emit_telemetry(:completed, %{doc_id: doc_id, source_type: source_type})
        :ok

      {:error, reason} ->
        emit_telemetry(:failed, %{
          doc_id: doc_id,
          source_type: source_type,
          error: inspect(reason)
        })

        {:error, reason}
    end
  end

  # ── HTML conversion ───────────────────────────────────────────────────────

  defp convert_html(args) do
    html = args["html"]
    opts = build_chrome_opts(args)

    with {:ok, base64_pdf} <- ChromicPDF.print_to_pdf({:html, html}, opts),
         {:ok, pdf_binary} <- decode_pdf(base64_pdf) do
      {:ok, pdf_binary}
    end
  end

  # ── URL conversion ────────────────────────────────────────────────────────

  defp convert_url(args) do
    url = args["url"]
    opts = build_chrome_opts(args)

    with :ok <- SsrfGuard.check(url),
         {:ok, base64_pdf} <- ChromicPDF.print_to_pdf({:url, url}, opts),
         {:ok, pdf_binary} <- decode_pdf(base64_pdf) do
      {:ok, pdf_binary}
    end
  end

  # ── chromic_pdf options ──────────────────────────────────────────────────

  @paper_sizes %{
    a0: {33.1, 46.8},
    a1: {23.4, 33.1},
    a2: {16.5, 23.4},
    a3: {11.7, 16.5},
    a4: {8.3, 11.7},
    a5: {5.8, 8.3},
    a6: {4.1, 5.8},
    a7: {2.9, 4.1},
    a8: {2.0, 2.9},
    a9: {1.5, 2.0},
    a10: {1.0, 1.5},
    us_letter: {8.5, 11.0},
    legal: {8.5, 14.0},
    tabloid: {11.0, 17.0}
  }

  defp build_chrome_opts(args) do
    print_to_pdf = %{}

    # — page size —
    print_to_pdf =
      if name = args["page_size"] do
        {w, h} = resolve_paper_size(name)
        print_to_pdf |> Map.put("paperWidth", w) |> Map.put("paperHeight", h)
      else
        print_to_pdf
      end

    # — landscape orientation —
    print_to_pdf =
      if args["landscape"], do: Map.put(print_to_pdf, "landscape", true), else: print_to_pdf

    # — background graphics —
    print_to_pdf =
      if args["background"] == false,
        do: Map.put(print_to_pdf, "printBackground", false),
        else: print_to_pdf

    # — margins (converted to inches) —
    print_to_pdf =
      if margins = args["margins"] do
        print_to_pdf
        |> maybe_put_margin("marginTop", margins["top"] || margins[:top])
        |> maybe_put_margin("marginBottom", margins["bottom"] || margins[:bottom])
        |> maybe_put_margin("marginLeft", margins["left"] || margins[:left])
        |> maybe_put_margin("marginRight", margins["right"] || margins[:right])
      else
        print_to_pdf
      end

    # — header / footer —
    header = args["header"]
    footer = args["footer"]

    print_to_pdf =
      if header or footer do
        print_to_pdf
        |> Map.put("displayHeaderFooter", true)
        |> then(fn m -> if header, do: Map.put(m, "headerTemplate", header), else: m end)
        |> then(fn m -> if footer, do: Map.put(m, "footerTemplate", footer), else: m end)
      else
        print_to_pdf
      end

    # Assemble the final option list — session-level options stay flat
    opts =
      [
        discard_stderr: true,
        print_to_pdf: print_to_pdf
      ]

    # — session-level options —
    opts = if args["disable_scripts"], do: Keyword.put(opts, :disable_scripts, true), else: opts
    opts = if args["offline"] != false, do: Keyword.put(opts, :offline, true), else: opts

    # — wait_for selector —
    opts =
      if wait = args["wait_for"] do
        # Accept both string-keyed and atom-keyed maps
        wait =
          case wait do
            %{"selector" => sel, "attribute" => attr} -> %{selector: sel, attribute: attr}
            %{selector: sel, attribute: attr} -> %{selector: sel, attribute: attr}
            _ -> nil
          end

        if wait, do: Keyword.put(opts, :wait_for, wait), else: opts
      else
        opts
      end

    opts
  end

  defp resolve_paper_size(name) when is_binary(name),
    do: resolve_paper_size(String.downcase(name))

  defp resolve_paper_size(name) when is_atom(name) do
    Map.get(@paper_sizes, name, {8.5, 11.0})
  end

  defp resolve_paper_size({_w, _h} = dims), do: dims

  defp resolve_paper_size(_), do: {8.5, 11.0}

  defp maybe_put_margin(map, key, nil), do: map
  defp maybe_put_margin(map, key, value) when is_number(value), do: Map.put(map, key, value)

  defp decode_pdf(base64_str) when is_binary(base64_str) do
    # Without an output path chromic_pdf returns base64-encoded PDF bytes
    {:ok, Base.decode64!(base64_str)}
  end

  # ── Persistence (OcrWorker pattern) ───────────────────────────────────────

  defp persist_result(pdf_binary, args) do
    doc_id = args["doc_id"]
    filename = args["filename"] || "converted.pdf"
    label = "Convert (#{Date.utc_today()})"
    doc = Repo.get(Document, doc_id)

    if is_nil(doc) do
      emit_telemetry(:persist_failed, %{doc_id: doc_id, error: :not_found})
    else
      case Storage.put(pdf_binary, name: filename, content_type: "application/pdf") do
        {:ok, ref} ->
          source_map = %{
            "storage_ref" => %{
              "adapter" => to_string(ref.adapter),
              "key" => ref.key,
              "name" => ref.name,
              "content_type" => ref.content_type,
              "byte_size" => ref.byte_size
            },
            "filename" => filename
          }

          {:ok, _rev} = Documents.create_revision(doc, label: label, source: source_map)
          emit_telemetry(:persisted, %{doc_id: doc_id, revision_label: label})

        {:error, reason} ->
          emit_telemetry(:persist_failed, %{doc_id: doc_id, error: inspect(reason)})
      end
    end
  end

  # ── Telemetry ─────────────────────────────────────────────────────────

  defp emit_telemetry(event, metadata) do
    :telemetry.execute([:quire, :convert, event], %{duration: nil}, metadata)
  rescue
    _ -> :ok
  end
end
