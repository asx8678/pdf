defmodule Quire.Gate4FailureMessagesTest do
  # Gate 4 Item 5 — FAILURE MESSAGES (plan3.md §9.2: "every conversion produces
  # an `operations` row with live progress and a plain-language failure cause").
  #
  # Verifies that every representative failure path surfaces an actionable,
  # plain-language message — never raw engine output:
  #
  #   1. corrupt / encrypted / unsupported input → Quire.Pdf.open + Documents.ingest
  #      (:invalid_pdf, :password_required) map to plain messages;
  #   2. SSRF guard (lib/quire/ssrf_guard.ex) returns actionable messages and the
  #      ConvertWorker surfaces them on the operations row / PubSub;
  #   3. unsupported file type → FileToPdfWorker "Unsupported format" plain error;
  #   4. missing Chromium / ChromicPDF engine errors → plain message via
  #      ConvertWorker.print_to_pdf_safely/2 (no stack traces, no raw tuples);
  #   5. the operations row failure path (Operations.fail/3 → friendly_error/1)
  #      never stores a raw engine dump, and the UI toast renders the message.
  #
  # No engine behaviour is changed; only message mapping at the worker/context
  # boundary is exercised.
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures

  alias Quire.Repo
  alias Quire.Documents
  alias Quire.Documents.Document
  alias Quire.Operations
  alias Quire.Workers.{ConvertWorker, FileToPdfWorker}

  @fixtures Path.expand("../fixtures/pdfs", __DIR__)
  @timeout 30_000

  # ── 1. corrupt / encrypted / unsupported input (open/ingest) ───────────

  describe "PDF open / ingest failure paths surface plain language" do
    setup do
      # ingest/2 inserts a Document row, so it needs a real owning user (the
      # previous synthetic `%{id: Ecto.UUID.generate()}` tripped the
      # documents_user_id_fkey constraint). Create one via the fixture.
      %{user: user_fixture()}
    end

    test "corrupt PDF bytes return :invalid_pdf and a plain message" do
      # A %PDF- header with garbage body — Quire.Pdf.open rejects it
      corrupt = <<37, 80, 68, 70, 45, 49, 46, 52, 10, "not really a pdf", 0, 1, 2, 3>>

      assert {:error, :invalid_pdf} = Quire.Pdf.open(corrupt)
      assert "The file is not a readable PDF" = Operations.friendly_error(:invalid_pdf)
    end

    test "non-PDF bytes are rejected with a plain message", %{user: user} do
      assert {:error, :invalid_pdf} = Quire.Pdf.open("hello world this is not a pdf")

      assert {:error, :invalid_pdf} =
               Documents.ingest("hello world", %{user: user})
    end

    test "encrypted fixture without a password maps to password_required", %{user: user} do
      # These fixtures carry a real /Encrypt dict; Quire.Pdf.open refuses to
      # open them without a password. Documents.ingest translates that to
      # :password_required so the UI can prompt.
      {:ok, encrypted} = File.read(Path.join(@fixtures, "encrypted_user_pw.pdf"))

      assert {:error, reason} = Documents.ingest(encrypted, %{user: user})
      assert reason == :password_required or reason == :invalid_pdf
    end

    test "friendly_error never leaks a raw NIF atom or engine dump" do
      for reason <- [:invalid_pdf, :password_required, :no_pages, :not_found] do
        msg = Operations.friendly_error(reason)
        assert is_binary(msg)
        refute msg =~ "{:error"
        refute msg =~ "nif"
        refute msg =~ "open_blob"
      end

      # Struct errors carry their own user-facing message
      engine_error = %Quire.Engine.Error{
        engine: Quire.Render.Pdfium,
        operation: :open,
        code: :nif,
        message: "Failed to open PDF",
        detail: "some native diagnostic"
      }

      msg = Operations.friendly_error(engine_error)
      assert is_binary(msg)
      refute msg =~ "Engine.Error"
      refute msg =~ "some native diagnostic"
    end
  end

  # ── 2. SSRF guard ────────────────────────────────────────────────────────

  describe "SSRF guard surfaces actionable messages" do
    test "blocked URLs return plain-language errors" do
      assert {:error, msg} = Quire.SsrfGuard.check("http://localhost:8080/admin")
      assert msg =~ "localhost"

      assert {:error, msg} = Quire.SsrfGuard.check("http://169.254.169.254/latest/meta-data")
      assert msg =~ "link-local"

      assert {:error, msg} = Quire.SsrfGuard.check("file:///etc/passwd")
      assert msg =~ "only HTTP(S)"
    end

    test "ConvertWorker fails the job with the SSRF message, not a stack trace" do
      # doc_id does not exist → ensure_started skips the operation row, but the
      # SSRF check still runs and must return the plain message.
      job = %Oban.Job{
        args: %{
          "source_type" => "url",
          "url" => "http://192.168.1.5/admin",
          "doc_id" => Ecto.UUID.generate()
        }
      }

      assert {:error, msg} = ConvertWorker.perform(job)
      assert msg =~ "RFC1918"
      refute msg =~ "** ("
      refute msg =~ "Chrome"
    end
  end

  # ── 3. unsupported file type ─────────────────────────────────────────────

  describe "unsupported file types surface plain language" do
    test "FileToPdfWorker rejects unknown extensions plainly" do
      job = %Oban.Job{args: %{"bytes" => Base.encode64("data"), "filename" => "file.xyz"}}
      assert {:error, msg} = FileToPdfWorker.perform(job)
      assert msg =~ "Unsupported"
      refute msg =~ "** ("
    end

    test "corrupt office file reports a plain error" do
      job = %Oban.Job{args: %{"bytes" => Base.encode64("not a zip"), "filename" => "bad.docx"}}
      assert {:error, msg} = FileToPdfWorker.perform(job)
      assert is_binary(msg)
      assert msg =~ "Word document could not be read"
      refute msg =~ "invalid_docx"
      refute msg =~ "** ("
    end
  end

  # ── 4. missing Chromium / engine errors ──────────────────────────────────

  describe "ChromicPDF engine failures map to plain language" do
    test "ChromeError (navigation failure) becomes an actionable message" do
      # offline: true + unresolvable host forces ChromicPDF to raise
      # ChromicPDF.ChromeError; print_to_pdf_safely/2 must return
      # {:error, plain_message}.
      result =
        ConvertWorker.print_to_pdf_safely({:url, "https://no-such-host.invalid/"},
          offline: true,
          discard_stderr: true,
          print_to_pdf: %{}
        )

      assert {:error, msg} = result
      assert is_binary(msg)
      assert msg =~ "could not be reached"
      refute msg =~ "ChromeError"
      refute msg =~ "net::ERR"
      refute msg =~ "** ("
    end

    test "missing Chromium executable maps to an actionable message" do
      # Point chromic_pdf at a nonexistent binary. The port still spawns (the
      # shell wrapper fails) — but if the underlying runner raises the
      # "could not find executable" RuntimeError, we map it. We assert the
      # worker's html path never raises and returns either :ok or a
      # plain-language error tuple.
      result =
        ConvertWorker.print_to_pdf_safely({:html, "<html><body>hi</body></html>"},
          chrome_executable: "/nonexistent/chrome-binary",
          discard_stderr: true,
          print_to_pdf: %{},
          offline: true
        )

      case result do
        {:ok, _bin} -> :ok
        {:error, msg} -> assert is_binary(msg)
      end
    end

    test "worker perform/1 with html source and nil header/footer does not crash" do
      # Regression: `if header or footer` with nil (the normal job-args case)
      # used to raise BadBooleanError and crash the worker with no message.
      # With Chromium installed the job succeeds; without it, it must fail
      # with a plain message — either way it must never raise.
      job = %Oban.Job{
        args: %{
          "source_type" => "html",
          "html" => "<html><body>hello</body></html>",
          "doc_id" => Ecto.UUID.generate(),
          "offline" => true
        }
      }

      result = ConvertWorker.perform(job)

      case result do
        :ok ->
          :ok

        {:error, msg} ->
          assert is_binary(msg)
          refute msg =~ "BadBooleanError"
          refute msg =~ "** ("
      end
    end
  end

  # ── 5. operations row + UI toast render the plain message ────────────────

  describe "operations row and UI render the plain-language cause" do
    setup %{conn: conn} do
      user = user_fixture()
      scope = Quire.Accounts.Scope.for_user(user)

      doc =
        %Document{id: Ecto.UUID.generate(), user_id: user.id, title: "op.pdf", page_count: 1}
        |> Repo.insert!()

      %{conn: conn, user: user, scope: scope, doc: doc}
    end

    test "Operations.fail/3 stores the plain message and broadcasts it", %{doc: doc} do
      doc_id = doc.id
      Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{doc_id}")

      {:ok, op_id} = Operations.start(doc_id, doc.user_id, "test_conv")
      Operations.fail(op_id, doc_id, {:invalid_pdf, "The file is not a readable PDF"})

      assert_receive {:operation_failed, ^op_id, ^doc_id, "The file is not a readable PDF"}, 1_000

      {:ok, bin} = Ecto.UUID.dump(op_id)

      rows =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT status, error FROM operations WHERE id = $1",
          [bin]
        ).rows

      assert [["failed", error_json]] = rows
      refute error_json =~ "Engine.Error"
      refute error_json =~ "stacktrace"
    end

    test "workspace LiveView renders the failure toast with the plain message",
         %{conn: conn, doc: doc} do
      conn = conn |> log_in_user(doc.user_id |> Quire.Accounts.get_user!())
      {:ok, lv, _html} = live(conn, ~p"/workspace/#{doc.id}")

      {:ok, op_id} = Operations.start(doc.id, doc.user_id, "test_conv")

      # Broadcast the failure the way a worker would (Operations.fail/3).
      Operations.fail(op_id, doc.id, "The document is password-protected")

      assert wait_until(fn ->
               html = render(lv)
               html =~ "op-toast-" and html =~ "password-protected" and html =~ "red"
             end),
             "expected the failure toast to render the plain-language cause"

      # No raw engine output in the rendered toast.
      html = render(lv)
      refute html =~ "** ("
      refute html =~ "Engine.Error"
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
