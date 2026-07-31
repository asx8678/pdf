defmodule Quire.Workers.ConvertWorker do
  require Logger

  @moduledoc ~S"""
  Oban worker for HTML/URL to PDF conversion via chromic_pdf (§T-072).

  Two source types — `html` (a self-contained HTML string) and `url` (a
  remote URL fetched and printed through the SSRF guard) — both producing
  a new revision of an existing document.

  ## Queue

  Runs on the `:convert` queue, serialised (concurrency 1, §7.2).

  The per-job Chrome reaping (prepare_job_profile/0 + reap_chromium/1) relies
  on this serialisation: exactly one job at a time mutates the on-demand
  Agent's `:chrome_args` and owns the marker. The `:convert` queue
  concurrency MUST stay 1 — raising it lets concurrent jobs clobber each
  other's markers and defeat cleanup. (FileToPdfWorker also fires on
  `:convert`, so it inherits the guarantee.)

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

    operation =
      case Quire.Operations.ensure_started(args, "convert_" <> source_type) do
        {:ok, op_id, _doc, _user} -> {:ok, op_id, doc_id}
        _ -> :skip
      end

    case operation do
      {:ok, op_id, doc} -> Quire.Operations.progress(op_id, doc, 10)
      :skip -> :ok
    end

    result =
      case source_type do
        "html" -> convert_html(args)
        "url" -> convert_url(args)
        other -> {:error, "Unknown source_type '#{other}'. Expected 'html' or 'url'."}
      end

    case {result, operation} do
      {{:ok, pdf_binary}, {:ok, op_id, doc}} ->
        Quire.Operations.progress(op_id, doc, 90)
        persist_result(pdf_binary, args)
        Quire.Operations.finish(op_id, doc)
        emit_telemetry(:completed, %{doc_id: doc_id, source_type: source_type})
        :ok

      {{:ok, pdf_binary}, :skip} ->
        persist_result(pdf_binary, args)
        emit_telemetry(:completed, %{doc_id: doc_id, source_type: source_type})
        :ok

      {{:error, reason}, {:ok, op_id, doc}} ->
        Quire.Operations.fail(op_id, doc, reason)

        emit_telemetry(:failed, %{
          doc_id: doc_id,
          source_type: source_type,
          error: inspect(reason)
        })

        {:error, reason}

      {{:error, reason}, :skip} ->
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

    with {:ok, base64_pdf} <- print_to_pdf_safely({:html, html}, opts),
         {:ok, pdf_binary} <- decode_pdf(base64_pdf) do
      {:ok, pdf_binary}
    end
  end

  # ── URL conversion ────────────────────────────────────────────────────────

  defp convert_url(args) do
    url = args["url"]
    opts = build_chrome_opts(args)

    with :ok <- SsrfGuard.check(url),
         {:ok, base64_pdf} <- print_to_pdf_safely({:url, url}, opts),
         {:ok, pdf_binary} <- decode_pdf(base64_pdf) do
      {:ok, pdf_binary}
    end
  end

  @doc false
  # ChromicPDF raises `ChromicPDF.ChromeError` (navigation failures, dead
  # targets) and a plain `RuntimeError` when no Chromium executable can be
  # found, instead of returning `{:error, _}`. Rescue and map to a
  # plain-language cause so the operations row (`Operations.fail/3`) and the
  # UI toast surface something a user can act on — never an engine dump.
  def print_to_pdf_safely(source, opts) do
    {marker, restore} = prepare_job_profile()

    try do
      ChromicPDF.print_to_pdf(source, opts)
    rescue
      e in [ChromicPDF.ChromeError] -> {:error, chrome_error_message(e)}
      e -> {:error, generic_chrome_message(e)}
    after
      # Best-effort cleanup on every exit path. In on-demand mode ChromicPDF
      # shuts down its own supervision tree after the job but leaves the
      # spawned Chrome binary running on macOS until the whole VM exits — so
      # reap exactly the instance spawned for this job, tagged with a unique
      # per-job --user-data-dir profile. The GUI Chrome and other tools'
      # instances never carry the marker and are never touched. Safe() keeps
      # this from crashing the worker or masking a produced PDF.
      safe(fn -> restore.() end)
      safe(fn -> reap_chromium(marker) end)
    end
  end

  # Never let cleanup crash the worker or mask an already-produced PDF on any
  # path. restore.() and reap_chromium/1 are best-effort/idempotent and must
  # survive ps / kill / Agent weirdness, including an Agent that died in a
  # concurrent (unserialised) launch config update.
  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
    :throw, _ -> :ok
  end

  # Give this job's temporary Chrome a unique --user-data-dir profile so the
  # reaper can identify and terminate exactly the process tree it spawned.
  # Only on-demand mode holds an Agent with the launch config to update; in
  # pool mode (prod default) the shared instance must never be touched, so
  # the marker stays nil and reaping is a no-op. (test.exs does enable
  # on_demand, so "pool mode" here really means "no on-demand Agent yet".)
  #
  # The marker is MERGED into the existing :chrome_args — it never clobbers
  # other operator-configured flags (e.g. --no-sandbox) — and restore puts
  # the prior value back verbatim, so nothing leaks across jobs.
  defp prepare_job_profile do
    case find_on_demand_agent() do
      nil ->
        maybe_warn_missing_agent()
        {nil, nil}

      agent ->
        marker =
          Path.join(
            System.tmp_dir!(),
            "quire-chrome-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
          )

        try do
          prior = Agent.get(agent, &Keyword.get(&1, :chrome_args))

          Agent.update(agent, fn cfg ->
            Keyword.update(cfg, :chrome_args, new_chrome_args(marker), &add_marker(&1, marker))
          end)

          {marker, fn -> restore_chrome_args(agent, prior) end}
        rescue
          # Agent died (supervisor restarting): fall back to no marker — the
          # job still runs, only precise per-job reaping is lost.
          _ -> {nil, nil}
        end
    end
  end

  # chromic_pdf's :chrome_args is a binary, a keyword list (:append / :remove),
  # or absent. Build a fresh keyword that appends only our marker without
  # assuming any prior shape.
  defp new_chrome_args(marker), do: [append: ["--user-data-dir=" <> marker]]

  # Add our marker to any existing :append list, keeping prior entries intact.
  defp add_marker(existing, marker) do
    kw =
      case existing do
        bin when is_binary(bin) -> [append: List.wrap(bin)]
        kw when is_list(kw) -> kw
        _ -> []
      end

    marker_arg = "--user-data-dir=" <> marker

    Keyword.update(kw, :append, [marker_arg], fn appends ->
      (List.wrap(appends) ++ [marker_arg]) |> Enum.uniq()
    end)
  end

  # Put the launch config back to exactly what it was before the job —
  # including any pre-existing :chrome_args the job had to merge into.
  defp restore_chrome_args(agent, prior) do
    Agent.update(agent, fn cfg ->
      case prior do
        value when value in [nil, []] -> Keyword.delete(cfg, :chrome_args)
        value -> Keyword.put(cfg, :chrome_args, value)
      end
    end)
  end

  # If on-demand mode is configured but the Agent can't be found (e.g. a
  # chromic_pdf upgrade restructured its internals), per-job reaping silently
  # degrades to a no-op and Chrome would leak again — surface that loudly.
  defp maybe_warn_missing_agent do
    if Keyword.get(Application.get_env(:quire, :chromic_pdf_opts, []), :on_demand, false) do
      Logger.warning(
        "ChromicPDF is configured with on_demand: true but no on-demand Agent was found; " <>
          "per-job Chrome reaping is DISABLED. Check find_on_demand_agent/0 against " <>
          "chromic_pdf internals (pinned == 1.17.1)."
      )
    end
  end

  defp find_on_demand_agent do
    with pid when is_pid(pid) <- Process.whereis(ChromicPDF) do
      pid
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {Agent, agent_pid, :worker, _} -> agent_pid
        _ -> nil
      end)
    else
      _ -> nil
    end
  end

  # Terminate the headless Chrome instance spawned for this job. Identified
  # by its unique per-job --user-data-dir marker (see prepare_job_profile/0),
  # so we only ever kill exactly the process tree we spawned. TERM first
  # (Chrome exits gracefully), then KILL stragglers.
  defp reap_chromium(marker) when is_binary(marker) do
    for pid <- chromium_pids(marker) do
      System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
    end

    wait_for_chromium_exit(marker)

    for pid <- chromium_pids(marker) do
      System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
    end

    File.rm_rf(marker)
  end

  defp reap_chromium(_), do: :ok

  @doc false
  # Boot-time cleanup: terminate orphaned on-demand Chrome instances left
  # behind by a crashed previous run (worker killed mid-print, VM killed,
  # ...). Matches only instances Quire spawned — they all carry a
  # --user-data-dir=.../quire-chrome-... profile — so the GUI Chrome and
  # any other tool's instances are never touched. Also removes leftover
  # per-job profile dirs.
  def sweep_stale_chromium do
    # Orphans from a dead BEAM get reparented to launchd (ppid 1). A live
    # concurrent BEAM's Chrome (e.g. `mix test` next to `mix phx.server`)
    # keeps its BEAM as parent — ppid != 1 — and must never be touched.
    for {pid, ppid} <- chromium_processes("quire-chrome-"), ppid == 1 do
      System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
    end

    # Remove leftover profile dirs — but only those no longer claimed by a
    # live owner. After the kill above, all surviving marker processes are
    # live (ppid != 1) instances of a different concurrent BEAM sharing the
    # same tmp root; deleting their in-flight profile dir (SessionState /
    # singleton lock) would corrupt that active conversion. Skip rm_rf for
    # any dir whose name token appears in a live (ppid != 1) marker argv.
    live = live_marker_argv()

    for dir <- Path.wildcard(Path.join(System.tmp_dir!(), "quire-chrome-*")) do
      token = Path.basename(dir)

      unless Enum.any?(live, &String.contains?(&1, token)) do
        File.rm_rf(dir)
      end
    end

    :ok
  end

  # {pid, ppid} pairs whose argv carries this marker as a --user-data-dir.
  # Requiring the --user-data-dir= prefix means a random unrelated process
  # that merely mentions the marker substring is never matched. Lines that
  # fail to parse (ps output can be briefly inconsistent) are skipped, never
  # raised on — the reaper must survive any ps weirdness.
  defp chromium_processes(marker) do
    {out, _} = System.cmd("ps", ["-eo", "pid=,ppid=,args="])

    out
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      with [_, pid, ppid] <- Regex.run(~r/^\s*(\d+)\s+(\d+)\s+/, line),
           # Require both a --user-data-dir= and the marker token so a random
           # unrelated process that merely mentions the token is never matched,
           # while both the per-job full-path marker and the sweep's bare
           # "quire-chrome-" token are correctly found.
           true <- String.contains?(line, "--user-data-dir="),
           true <- String.contains?(line, marker) do
        [{String.to_integer(pid), String.to_integer(ppid)}]
      else
        _ -> []
      end
    end)
  end

  # argv of live marker Chrome processes owned by a live (ppid != 1) process
  # — a different concurrent BEAM sharing the tmp root, whose profile dir a
  # parallel boot sweep must not delete.
  defp live_marker_argv do
    {out, _} = System.cmd("ps", ["-eo", "ppid=,args="])

    out
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(~r/^\s*(\d+)\s+(.*)/, line) do
        [_, ppid, args] ->
          if String.to_integer(ppid) != 1 and String.contains?(args, "--user-data-dir=") and
               String.contains?(args, "quire-chrome-") do
            [args | acc]
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  defp chromium_pids(marker) do
    for {pid, _ppid} <- chromium_processes(marker), do: pid
  end

  # Poll up to ~2 s for the instance to exit after TERM.
  defp wait_for_chromium_exit(marker, tries \\ 50)

  defp wait_for_chromium_exit(_marker, 0), do: :ok

  defp wait_for_chromium_exit(marker, tries) do
    if chromium_pids(marker) == [] do
      :ok
    else
      Process.sleep(40)
      wait_for_chromium_exit(marker, tries - 1)
    end
  end

  defp chrome_error_message(%{error: "net::ERR_" <> code}) do
    "The web page could not be reached (#{code}). Check the URL and your internet connection."
  end

  defp chrome_error_message(%{error: {kind, _}})
       when kind in [:exception_thrown, :console_api_called] do
    "The web page could not be printed because a script on it failed. Try again with scripts disabled."
  end

  defp chrome_error_message(_), do: "The web page could not be printed by the browser engine."

  defp generic_chrome_message(e) do
    message = Exception.message(e)

    if String.contains?(message, "could not find executable") do
      "The browser engine (Chromium) is not installed or could not be found. Install Google Chrome or Chromium to convert web pages to PDF."
    else
      "The web page could not be printed: #{message}"
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

    # Guard against nil (job args routinely omit header/footer): `if header or
    # footer` raises BadBooleanError on nil, crashing the worker instead of
    # returning a plain-language error.
    print_to_pdf =
      if is_binary(header) or is_binary(footer) do
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

  defp maybe_put_margin(map, _key, nil), do: map
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

          {:ok, new_rev} = Documents.create_revision(doc, label: label, source: source_map)
          broadcast_revision(doc, new_rev)
          emit_telemetry(:persisted, %{doc_id: doc_id, revision_label: label})

        {:error, reason} ->
          emit_telemetry(:persist_failed, %{doc_id: doc_id, error: inspect(reason)})
      end
    end
  end

  defp broadcast_revision(doc, new_rev) do
    # Update the document's current_revision pointer and notify the workspace
    # so the UI clears its "converting" state and the viewer reloads (Gate 4).
    doc
    |> Ecto.Changeset.change(%{current_revision_id: new_rev.id})
    |> Repo.update()

    Phoenix.PubSub.broadcast(Quire.PubSub, "document:#{doc.id}", {:revision, new_rev})
  end

  # ── Telemetry ─────────────────────────────────────────────────────────

  defp emit_telemetry(event, metadata) do
    :telemetry.execute([:quire, :convert, event], %{duration: nil}, metadata)
  rescue
    _ -> :ok
  end
end
