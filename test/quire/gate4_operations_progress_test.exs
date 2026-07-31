defmodule Quire.Gate4OperationsProgressTest do
  # Gate 4 Item 2 — OPERATIONS + LIVE PROGRESS (plan3.md §7.5 lines
  # 1247-1299, §9.2 line 1489-1493).
  #
  # Verifies, for a representative conversion:
  #   1. an `operations` row is created for every conversion run (kind,
  #      input, started_at), with the full state transition
  #      running → completed and progress 0 → 100;
  #   2. progress % is broadcast live on PubSub `"document:{doc_id}"`
  #      while the conversion is running, monotonically;
  #   3. the workspace LiveView subscribes to that topic and renders the
  #      T-086 status strip + progress toasts live while the conversion
  #      runs, then flips to the completed state.
  #
  # Uses the real PDF→Image worker (PDFium + vix, no Chromium). JPEG
  # re-encoding is slow enough (~1 s for 80 pages @300 dpi) that the
  # LiveView can be observed rendering progress *while the conversion is
  # still running*; the PubSub stream is the reliable live channel because
  # the Ecto sandbox isolates the worker's DB writes from the test process
  # (verified during gate work — a poll of the operations table from the
  # test process only ever saw the row after the worker committed).
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures

  alias Quire.Repo
  alias Quire.Documents.{Document, Revision}

  @fixtures Path.expand("../fixtures/pdfs", __DIR__)
  @timeout 30_000

  # ── Setup helpers ──────────────────────────────────────────────────────

  defp doc_with_revision(user, filename, page_count) do
    bytes = File.read!(Path.join(@fixtures, filename))
    {:ok, ref} = Quire.Storage.put(bytes, name: filename, content_type: "application/pdf")

    doc =
      %Document{
        id: Ecto.UUID.generate(),
        user_id: user.id,
        title: filename,
        page_count: page_count
      }
      |> Repo.insert!()

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

    rev =
      %Revision{document_id: doc.id, label: "Original", source: source_map}
      |> Repo.insert!()

    doc
    |> Ecto.Changeset.change(%{current_revision_id: rev.id})
    |> Repo.update!()

    {doc, rev}
  end

  defp op_rows(doc_id) do
    {:ok, bin} = Ecto.UUID.dump(doc_id)

    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT kind, status, progress, started_at IS NOT NULL, finished_at IS NOT NULL, input, error FROM operations WHERE document_id = $1",
      [bin]
    ).rows
  end

  defp run_pdf_to_image(doc_id, rev_id, format, pages) do
    %Oban.Job{
      args: %{
        "doc_id" => doc_id,
        "revision_id" => rev_id,
        "format" => format,
        "dpi" => 300,
        "page_range" => pages
      }
    }
    |> Quire.Workers.PdfToImageWorker.perform()
  end

  defp start_conversion(doc_id, rev_id, format, pages) do
    task = Task.async(fn -> run_pdf_to_image(doc_id, rev_id, format, pages) end)
    Ecto.Adapters.SQL.Sandbox.allow(Quire.Repo, self(), task.pid)
    task
  end

  defp collect_progress_stream(doc_id) do
    do_collect(doc_id, [])
  end

  defp do_collect(doc_id, acc) do
    receive do
      {:operation_progress, op_id, pct} ->
        do_collect(doc_id, [{:progress, op_id, pct} | acc])

      {:operation_completed, op_id, ^doc_id} ->
        Enum.reverse([{:completed, op_id} | acc])

      {:operation_failed, op_id, ^doc_id, reason} ->
        Enum.reverse([{:failed, op_id, reason} | acc])
    after
      10_000 -> Enum.reverse(acc)
    end
  end

  defp progress_pcts(stream) do
    Enum.map(stream, fn
      {:progress, _op_id, pct} -> pct
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ── 1. operations row + state transitions (real conversion) ───────────

  describe "a conversion writes an operations row and transitions states" do
    test "PDF→Image (jpeg) conversion: row running→completed at 100", %{conn: _conn} do
      user = user_fixture()
      {doc, rev} = doc_with_revision(user, "500_pages.pdf", 500)
      doc_id = doc.id

      Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{doc_id}")

      test_pid = self()

      :telemetry.attach(
        "gate4-op-#{System.unique_integer([:positive])}",
        [:quire, :operation, :completed],
        fn event, _measurements, _meta, _config -> send(test_pid, {:telemetry_event, event}) end,
        nil
      )

      task = start_conversion(doc_id, rev.id, "jpeg", Enum.to_list(0..79))

      # Live progress is broadcast while the conversion runs.
      stream = collect_progress_stream(doc_id)
      assert Task.await(task, @timeout) == :ok

      pcts = progress_pcts(stream)

      # The row exists, transitions running → completed, progress 0 → 100.
      assert [row] = op_rows(doc_id)
      [kind, status, pct, started, finished, input, error] = row
      assert kind == "pdf_to_image"
      assert status == "completed"
      assert pct == 100
      assert started
      assert finished
      assert is_map(Jason.decode!(input))
      assert error == nil

      # The very first broadcast is 0 % and the last is 100 %.
      assert hd(pcts) == 0
      assert List.last(pcts) == 100
      assert_receive {:telemetry_event, [:quire, :operation, :completed]}, 5_000
    end

    test "a failed conversion records a plain-language cause on the row", %{conn: _conn} do
      user = user_fixture()
      {doc, rev} = doc_with_revision(user, "500_pages.pdf", 500)
      doc_id = doc.id

      Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{doc_id}")

      # Zero pages is rejected by the worker *after* the operations row is
      # created, so the failure path (fail/3) is exercised end-to-end.
      task = start_conversion(doc_id, rev.id, "png", [])

      stream = collect_progress_stream(doc_id)
      result = Task.await(task, @timeout)

      assert {:error, "No pages to render"} = result
      assert [row] = op_rows(doc_id)
      [_kind, status, _pct, started, finished, _input, error] = row
      assert status == "failed"
      assert started
      assert finished
      assert error != nil

      assert Enum.any?(stream, fn
               {:failed, _op_id, "The document has no pages to process"} -> true
               _ -> false
             end)
    end

    test "ConvertWorker (HTML→PDF engine) also creates a row and fails it plainly", %{conn: _conn} do
      user = user_fixture()
      {doc, _rev} = doc_with_revision(user, "simple_text.pdf", 1)
      doc_id = doc.id

      Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{doc_id}")

      # Unknown source_type is rejected after ensure_started/1 has created
      # the operations row, so the worker's fail/3 path is exercised.
      result =
        Quire.Workers.ConvertWorker.perform(%Oban.Job{
          args: %{"source_type" => "gopher", "doc_id" => doc_id}
        })

      assert {:error, msg} = result
      assert msg =~ "Unknown source_type"

      assert [row] = op_rows(doc_id)
      [kind, status, _pct, started, finished, _input, error] = row
      assert kind == "convert_gopher"
      assert status == "failed"
      assert started
      assert finished
      assert error != nil

      # The plain-language cause is broadcast on the document topic.
      assert_receive {:operation_failed, _op_id, ^doc_id, reason}, 5_000
      assert reason =~ "Unknown source_type"
    end

    test "worker with no pre-created operation row creates one via ensure_started", %{conn: _conn} do
      user = user_fixture()
      {doc, rev} = doc_with_revision(user, "mixed_page_sizes.pdf", 4)
      doc_id = doc.id

      # The job args deliberately omit "operation_id": the worker must
      # create its own operations row (§7.5 "Every worker MUST write
      # progress to the operations row").
      Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{doc_id}")

      result = run_pdf_to_image(doc_id, rev.id, "png", Enum.to_list(0..3))

      assert result == :ok
      assert [row] = op_rows(doc_id)
      [kind, status, pct, _started, _finished, _input, _error] = row
      assert kind == "pdf_to_image"
      assert status == "completed"
      assert pct == 100

      # The 0 % broadcast from start/1 is observable, then completion.
      assert_receive {:operation_progress, _op_id, 0}, 5_000
      assert_receive {:operation_completed, _op_id, ^doc_id}, 5_000
    end
  end

  # ── 2. live progress on PubSub while running ───────────────────────────

  describe "live progress broadcasts (PubSub)" do
    test "progress % is broadcast monotonically while the conversion runs", %{conn: _conn} do
      user = user_fixture()
      {doc, rev} = doc_with_revision(user, "500_pages.pdf", 500)
      doc_id = doc.id

      Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{doc_id}")

      task = start_conversion(doc_id, rev.id, "jpeg", Enum.to_list(0..79))
      stream = collect_progress_stream(doc_id)
      assert Task.await(task, @timeout) == :ok

      pcts = progress_pcts(stream)

      # An intermediate percentage was broadcast *while running* — this is
      # the "live progress" guarantee, not just start/finish.
      assert pcts != [], "expected at least one live progress broadcast"

      assert Enum.any?(pcts, &(&1 > 0 and &1 < 100)),
             "expected intermediate progress while running, got: #{inspect(pcts)}"

      # Monotonic, ending at 100, and completed with the document id.
      assert pcts == Enum.sort(pcts), "progress must be monotonic"
      assert List.last(pcts) == 100
      assert {:completed, op_id} = List.last(stream)
      assert is_binary(op_id)
    end

    test "broadcasts carry the operation id of the created row", %{conn: _conn} do
      user = user_fixture()
      {doc, rev} = doc_with_revision(user, "mixed_page_sizes.pdf", 4)
      doc_id = doc.id

      Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{doc_id}")

      task = start_conversion(doc_id, rev.id, "png", Enum.to_list(0..3))
      stream = collect_progress_stream(doc_id)
      assert Task.await(task, @timeout) == :ok

      [{:progress, op_id, _} | _] = stream

      {:ok, bin} = Ecto.UUID.dump(op_id)

      rows =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT status FROM operations WHERE id = $1",
          [bin]
        ).rows

      assert rows == [["completed"]]
    end
  end

  # ── 3. workspace LiveView status strip + toasts (subscription) ─────────

  describe "workspace LiveView status strip subscribes and renders progress" do
    test "a real conversion is rendered live in the T-086 status strip", %{conn: conn} do
      user = user_fixture()
      {doc, rev} = doc_with_revision(user, "500_pages.pdf", 500)
      doc_id = doc.id
      conn = conn |> log_in_user(user)

      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc_id}")

      # Run the conversion while the LiveView is mounted.
      task = start_conversion(doc_id, rev.id, "jpeg", Enum.to_list(0..79))

      # 3a. The status strip appears and shows a running operation — i.e. the
      # LiveView is subscribed to the document topic and re-renders on the
      # worker's PubSub broadcasts while the conversion is still running.
      assert wait_until(fn ->
               has_element?(lv, "#op-status-strip") and render(lv) =~ "1 operation running"
             end),
             "expected the T-086 status strip with 1 running operation during the conversion"

      # 3b. A progress toast for the operation appears with a live %.
      assert wait_until(fn ->
               html = render(lv)
               html =~ "Conversion in progress" and html =~ "op-toast-"
             end),
             "expected a live progress toast during the conversion"

      # 3c. The toast % advanced (renders a width) while still running.
      assert wait_until(fn -> render(lv) =~ "width: " end),
             "expected the toast progress bar to render during the conversion"

      # 3d. On completion the strip clears and the success toast renders.
      assert Task.await(task, @timeout) == :ok

      assert wait_until(fn ->
               html = render(lv)
               html =~ "Conversion complete" and not has_element?(lv, "#op-status-strip")
             end),
             "expected the completed toast and no running strip after the conversion finished"

      assert render(lv) =~ "width: 100%"
    end
  end

  # ── Polling helper ─────────────────────────────────────────────────────

  defp wait_until(fun, interval \\ 25, attempts \\ 1_200) do
    if fun.() do
      true
    else
      if attempts <= 0 do
        false
      else
        Process.sleep(interval)
        wait_until(fun, interval, attempts - 1)
      end
    end
  end
end
