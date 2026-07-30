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
        "page_size"      => "A4",                       # optional
        "landscape"      => false,                      # optional
        "background"     => true,                       # optional
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

  defp build_chrome_opts(args) do
    opts = [discard_stderr: true]

    opts = if args["page_size"], do: Keyword.put(opts, :page_size, args["page_size"]), else: opts
    opts = if args["landscape"], do: Keyword.put(opts, :landscape, true), else: opts
    opts = if args["background"] == false, do: Keyword.put(opts, :background, false), else: opts
    opts = if args["disable_scripts"], do: Keyword.put(opts, :disable_scripts, true), else: opts
    opts = if args["offline"] != false, do: Keyword.put(opts, :offline, true), else: opts

    if args["margins"] && args["margins"] != %{} do
      Keyword.put(opts, :margins, args["margins"])
    else
      opts
    end
  end

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
