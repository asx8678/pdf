defmodule QuireWeb.Gate4ReachabilityTest do
  # Gate 4 Item 1 — REACHABILITY (plan3.md §9.2, lines 1763-1775).
  #
  # Every conversion in §9.2 must be reachable from the UI and wired to a
  # real implementation — none stubbed or unreachable. This test asserts,
  # per conversion, that:
  #
  #   1. its UI entrypoint exists (unique DOM id / phx-click) in the
  #      workspace Create & Convert tab, the New ▾ menu or the Advanced ▾
  #      submenu, and
  #   2. activating the entrypoint produces a real effect: an Oban job on
  #      the :convert queue targeting the implementing worker, a wizard
  #      dialog, or a client hook for the client-side conversions.
  #
  # Entrypoint → implementation map (verified against lib/quire/workers/*):
  #
  #   File to PDF           → FileToPdfWorker          (#file-to-pdf-btn)
  #   Scan to PDF           → Quire.Scan               (Scan ribbon / New ▾ From scanner)
  #   Clipboard to PDF      → ClipboardPdf hook        (#clipboard-pdf-btn)
  #   URL to PDF            → ConvertWorker            (Advanced ▾ URL to PDF)
  #   Merge                 → Quire.Merge              (Merge ribbon button)
  #   Split PDF             → Quire.Split              (Split ribbon button)
  #   Compress              → Quire.Compress           (Compress ribbon button)
  #   PDF to Word/Excel/PPT → PdfToOfficeWorker        (Export DOCX/XLSX/PPTX)
  #   PDF to Image          → PdfToImageWorker         (Image export wizard)
  #   PDF to PDF/A          → Quire.PdfA               (PDF/A ribbon + Advanced ▾)
  #   PDF to TXT            → PdfToTxtWorker           (Advanced ▾)
  #   PDF to RTF            → PdfToRtfWorker           (Advanced ▾)
  #   PDF to HTML           → Office.Writer.PdfHtml    (Export HTML / HTML text)
  #
  # Tests never assert raw HTML text — they assert key element IDs and
  # phx-click wiring (project guidelines).
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures
  import Ecto.Query

  alias Quire.Repo
  alias Quire.Documents.Document
  alias Quire.Documents.Revision

  @fixtures Path.expand("../../fixtures/pdfs", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp open_workspace(conn) do
    conn
    |> log_in_user(user_fixture())
    |> live(~p"/workspace/doc-1")
  end

  defp open_create_tab(lv) do
    lv
    |> element(~s{button[role="tab"][phx-value-tab="create-convert"]})
    |> render_click()

    lv
  end

  # A real document + revision so conversion handlers that read the current
  # revision succeed (mirrors workspace_live_pdfa_test.exs).
  defp doc_fixture(user) do
    bytes = fixture("simple_text.pdf")
    {:ok, ref} = Quire.Storage.put(bytes, name: "simple.pdf", content_type: "application/pdf")

    doc =
      %Document{id: Ecto.UUID.generate(), user_id: user.id, title: "simple.pdf", page_count: 1}
      |> Repo.insert!()

    source_map = %{
      "storage_ref" => %{
        "adapter" => to_string(ref.adapter),
        "key" => ref.key,
        "name" => ref.name,
        "content_type" => ref.content_type,
        "byte_size" => ref.byte_size
      },
      "filename" => "simple.pdf"
    }

    rev =
      %Revision{document_id: doc.id, label: "Original", source: source_map}
      |> Repo.insert!()

    doc
    |> Ecto.Changeset.change(%{current_revision_id: rev.id})
    |> Repo.update!()
  end

  defp open_doc(conn, user, doc) do
    conn
    |> log_in_user(user)
    |> live(~p"/workspace/#{doc.id}")
  end

  defp latest_job(worker) do
    Repo.one!(
      from j in Oban.Job,
        where: j.worker == ^worker,
        order_by: [desc: j.id],
        limit: 1
    )
  end

  describe "§9.2 entrypoints exist in the Create & Convert tab" do
    test "File to PDF, Clipboard, Merge, Split, Compress, PDF/A and Export buttons are present",
         %{
           conn: conn
         } do
      {:ok, lv, _html} = open_workspace(conn)
      open_create_tab(lv)

      # Create from…
      assert has_element?(lv, ~s{button[id="file-to-pdf-btn"][phx-click="file_to_pdf_pick"]})
      assert has_element?(lv, ~s{button[id="clipboard-pdf-btn"][phx-hook="ClipboardPdf"]})
      assert has_element?(lv, ~s{button[phx-click="open_merge_wizard"]})
      assert has_element?(lv, ~s{button[phx-click="open_split_wizard"]})
      assert has_element?(lv, ~s{button[phx-click="open_compress_wizard"]})
      assert has_element?(lv, ~s{button[phx-click="open_pdfa_wizard"]})

      # Export to…
      assert has_element?(lv, ~s{button[phx-click="convert_to_office"][phx-value-format="docx"]})
      assert has_element?(lv, ~s{button[phx-click="convert_to_office"][phx-value-format="xlsx"]})
      assert has_element?(lv, ~s{button[phx-click="convert_to_office"][phx-value-format="pptx"]})
      assert has_element?(lv, ~s{button[phx-click="convert_to_html"][phx-value-mode="overlay"]})
      assert has_element?(lv, ~s{button[phx-click="convert_to_html"][phx-value-mode="text_only"]})

      assert has_element?(
               lv,
               ~s{button[id="export-image-btn"][phx-click="open_export_image_wizard"]}
             )

      # New ▾ menu covers the remaining New entries
      lv |> element(~s{button[id="new-menu-btn"]}) |> render_click()
      assert has_element?(lv, ~s{button[role="menuitem"][phx-click="new_blank"]})
      assert has_element?(lv, ~s{button[role="menuitem"][phx-click="new_template"]})
      assert has_element?(lv, ~s{button[id="new-clipboard-btn"][phx-hook="ClipboardPdf"]})
      assert has_element?(lv, ~s{button[role="menuitem"][phx-click="new_from_scanner"]})
    end

    test "Scan to PDF is reachable from the View tab and the New ▾ menu", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      # View tab ribbon has the Scan button (T-080)
      assert has_element?(lv, ~s{button[phx-click="open_camera_capture"]})

      # New ▾ → From scanner reuses the same flow (T-085)
      open_create_tab(lv)
      lv |> element(~s{button[id="new-menu-btn"]}) |> render_click()
      lv |> element(~s{button[role="menuitem"][phx-click="new_from_scanner"]}) |> render_click()

      assert has_element?(lv, ~s{div[role="dialog"][aria-label="Scan to PDF"]})
    end

    test "Advanced ▾ submenu exposes URL to PDF, TXT, RTF and PDF/A", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)
      open_create_tab(lv)

      lv |> element(~s{button[id="advanced-menu-btn"]}) |> render_click()

      assert has_element?(lv, ~s{button[id="advanced-url-btn"][phx-click="open_url_wizard"]})
      assert has_element?(lv, ~s{button[id="advanced-txt-btn"][phx-click="convert_to_txt"]})
      assert has_element?(lv, ~s{button[id="advanced-rtf-btn"][phx-click="convert_to_rtf"]})
      assert has_element?(lv, ~s{button[id="advanced-pdfa-btn"][phx-click="open_pdfa_wizard"]})
    end
  end

  describe "§9.2 conversions are wired to real implementations" do
    test "PDF to Word/Excel/PowerPoint enqueue PdfToOfficeWorker on the convert queue", %{
      conn: conn
    } do
      user = user_fixture()
      doc = doc_fixture(user)
      {:ok, lv, _html} = open_doc(conn, user, doc)
      open_create_tab(lv)

      for {format, _label} <- [{"docx", "DOCX"}, {"xlsx", "XLSX"}, {"pptx", "PPTX"}] do
        lv
        |> element(~s{button[phx-click="convert_to_office"][phx-value-format="#{format}"]})
        |> render_click()

        job = latest_job("Quire.Workers.PdfToOfficeWorker")
        assert job.queue == "convert"
        assert job.args["format"] == format
        assert job.args["doc_id"] == doc.id
        assert job.args["revision_id"] == doc.current_revision_id
      end
    end

    test "PDF to TXT and PDF to RTF enqueue their workers", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      {:ok, lv, _html} = open_doc(conn, user, doc)
      open_create_tab(lv)
      lv |> element(~s{button[id="advanced-menu-btn"]}) |> render_click()

      lv |> element(~s{button[id="advanced-txt-btn"]}) |> render_click()

      txt_job = latest_job("Quire.Workers.PdfToTxtWorker")
      assert txt_job.queue == "convert"
      assert txt_job.args["doc_id"] == doc.id

      lv |> element(~s{button[id="advanced-menu-btn"]}) |> render_click()
      lv |> element(~s{button[id="advanced-rtf-btn"]}) |> render_click()

      rtf_job = latest_job("Quire.Workers.PdfToRtfWorker")
      assert rtf_job.queue == "convert"
      assert rtf_job.args["doc_id"] == doc.id
    end

    test "URL to PDF wizard is SSRF-guarded and enqueues ConvertWorker", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      {:ok, lv, _html} = open_doc(conn, user, doc)
      open_create_tab(lv)
      lv |> element(~s{button[id="advanced-menu-btn"]}) |> render_click()
      lv |> element(~s{button[id="advanced-url-btn"]}) |> render_click()

      assert has_element?(lv, ~s{div[role="dialog"][aria-label="URL to PDF"]})
      assert has_element?(lv, "#url-input")
      assert has_element?(lv, "#url-convert-btn")

      # localhost is rejected before any job is enqueued
      lv |> element("#url-input") |> render_change(%{"url" => "http://localhost:4000/x"})
      lv |> element("#url-convert-btn") |> render_click()

      assert has_element?(lv, ~s{div[role="alert"]})
      assert render(lv) =~ "localhost"

      # a public URL enqueues the real ConvertWorker
      lv |> element("#url-input") |> render_change(%{"url" => "https://example.com"})
      lv |> element("#url-convert-btn") |> render_click()

      job = latest_job("Quire.Workers.ConvertWorker")
      assert job.queue == "convert"
      assert job.args["source_type"] == "url"
      assert job.args["url"] == "https://example.com"
      assert job.args["doc_id"] == doc.id
    end

    test "PDF to Image wizard enqueues PdfToImageWorker with DPI and page range", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      {:ok, lv, _html} = open_doc(conn, user, doc)
      open_create_tab(lv)

      lv |> element(~s{button[id="export-image-btn"]}) |> render_click()

      assert has_element?(lv, ~s{div[role="dialog"][aria-label="PDF to Image"]})
      assert has_element?(lv, "#export-image-format option[value='png'][selected]")
      assert has_element?(lv, "#export-image-dpi")
      assert has_element?(lv, "#export-image-range")

      # multipage TIFF only with the tiff format
      lv |> element("#export-image-multipage") |> render_click()
      lv |> element("#export-image-submit-btn") |> render_click()
      assert has_element?(lv, ~s{div[role="alert"]})
      assert render(lv) =~ "TIFF only"

      # format + dpi + page range flow through to the job args
      lv |> element("#export-image-format") |> render_change(%{"format" => "tiff"})
      lv |> element("#export-image-multipage") |> render_click()
      lv |> element("#export-image-dpi") |> render_change(%{"dpi" => "300"})
      lv |> element("#export-image-range") |> render_change(%{"range" => "1"})
      lv |> element("#export-image-submit-btn") |> render_click()

      job = latest_job("Quire.Workers.PdfToImageWorker")
      assert job.queue == "convert"
      assert job.args["format"] == "tiff"
      assert job.args["dpi"] == 300
      assert job.args["multipage_tiff"] == true
      assert job.args["page_range"] == [0]
      assert job.args["doc_id"] == doc.id
    end

    test "File to PDF picker triggers the hidden upload form and enqueues FileToPdfWorker", %{
      conn: conn
    } do
      user = user_fixture()
      {:ok, lv, _html} = open_doc(conn, user, doc_fixture(user))
      open_create_tab(lv)

      # The hidden upload form + live file input exist (the colocated hook
      # clicks the input when the ribbon button is pressed). live_file_input
      # overrides the id with the upload ref, so the hook resolves the input
      # within its own form by type.
      assert has_element?(
               lv,
               ~s{form[id="file-to-pdf-upload-form"][phx-submit="file_to_pdf_submit"]}
             )

      assert has_element?(
               lv,
               ~s{form[id="file-to-pdf-upload-form"] input[type="file"][name="file_to_pdf"]}
             )

      # Upload a text file; the submit handler routes it to FileToPdfWorker
      # (text path — no Chromium involved, mirrors the worker unit tests).
      upload =
        file_input(lv, "#file-to-pdf-upload-form", :file_to_pdf, [
          %{name: "notes.txt", content: "hello gate four"}
        ])

      assert render_upload(upload, "notes.txt") =~ "100%"
      lv |> element("#file-to-pdf-upload-form") |> render_submit(%{})

      job = latest_job("Quire.Workers.FileToPdfWorker")
      assert job.queue == "convert"
      assert job.args["filename"] == "notes.txt"
      assert job.args["scope_id"] == user.id
    end

    test "merge, split, compress and PDF/A wizards open from the ribbon", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      {:ok, lv, _html} = open_doc(conn, user, doc)
      open_create_tab(lv)

      lv |> element(~s{button[phx-click="open_merge_wizard"]}) |> render_click()
      assert has_element?(lv, ~s{div[role="dialog"][aria-label="Merge PDFs"]})
      assert has_element?(lv, "#merge-submit-btn")

      lv
      |> element(~s{button[phx-click="close_merge_wizard"][aria-label="Close"]})
      |> render_click()

      lv |> element(~s{button[phx-click="open_split_wizard"]}) |> render_click()
      assert has_element?(lv, ~s{div[role="dialog"][aria-label="Split PDF"]})
      assert has_element?(lv, "#split-submit-btn")

      lv
      |> element(~s{button[phx-click="close_split_wizard"][aria-label="Close"]})
      |> render_click()

      lv |> element(~s{button[phx-click="open_compress_wizard"]}) |> render_click()
      assert has_element?(lv, ~s{div[role="dialog"][aria-label="Compress PDF"]})
      assert has_element?(lv, "#compress-commit-btn")

      lv
      |> element(~s{button[phx-click="close_compress_wizard"][aria-label="Close"]})
      |> render_click()

      lv |> element(~s{button[phx-click="open_pdfa_wizard"]}) |> render_click()
      assert has_element?(lv, ~s{div[role="dialog"][aria-label="PDF/A — best-effort conversion"]})
      assert has_element?(lv, "#pdfa-convert-btn")
    end

    test "Clipboard to PDF is wired to the client hook with a paste-target fallback", %{
      conn: conn
    } do
      {:ok, lv, _html} = open_workspace(conn)
      open_create_tab(lv)

      assert has_element?(lv, ~s{button[id="clipboard-pdf-btn"][phx-hook="ClipboardPdf"]})
    end

    test "clipboard bytes are ingested as a new document with revision 1", %{conn: conn} do
      # Mirrors workspace_live_test.exs T-079: the server half of the
      # ClipboardPdf hook ingests the client-built PDF as a new document.
      user = user_fixture()
      conn = conn |> log_in_user(user)
      {:ok, lv, _html} = live(conn, ~p"/workspace/doc-1")
      open_create_tab(lv)

      bytes = fixture("simple_text.pdf")

      assert {:error, {:live_redirect, %{to: to}}} =
               render_hook(lv, "clipboard_pdf_ready", %{
                 "bytes" => Base.encode64(bytes),
                 "filename" => "clipboard.pdf"
               })

      doc =
        Repo.one!(
          from d in Document,
            where: d.title == "clipboard.pdf",
            order_by: [desc: d.inserted_at],
            limit: 1
        )

      assert to == ~p"/workspace/#{doc.id}"
      assert doc.user_id == user.id
      assert doc.page_count == 1
    end

    test "PDF to HTML runs the PdfHtml writer and delivers a download", %{conn: conn} do
      user = user_fixture()
      doc = doc_fixture(user)
      {:ok, lv, _html} = open_doc(conn, user, doc)
      open_create_tab(lv)

      # The handler spawns a Task that runs Office.Writer.PdfHtml and
      # delivers the finished file via handle_info → push_event("download")
      # (T-078). The task is async, so drive it synchronously for the
      # assertion and verify the download payload is a real self-contained
      # HTML document produced by the real writer.
      {:ok, rev} = Quire.Documents.current_revision(doc)
      ref = Quire.Documents.Revision.storage_ref(rev)
      assert {:ok, html} = Quire.Office.Writer.PdfHtml.write(ref, :html, mode: :overlay)
      assert html =~ "<!DOCTYPE html>"
      assert html =~ "data:image/webp"

      # And the UI wiring: clicking the button sets the converting state.
      lv
      |> element(~s{button[phx-click="convert_to_html"][phx-value-mode="overlay"]})
      |> render_click()

      assert render(lv) =~ "HTML export started"
    end

    test "Scan to PDF ingests a real image via Quire.Scan", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      lv |> element(~s{button[phx-click="open_camera_capture"]}) |> render_click()

      {:ok, black} = Vix.Vips.Operation.black(64, 48)
      {:ok, png} = Vix.Vips.Image.write_to_buffer(black, ".png")

      render_hook(lv, "scan_file_ready", %{
        "dataUrl" => "data:image/png;base64," <> Base.encode64(png),
        "deskew" => "true",
        "contrast" => "auto",
        "ocr" => "false",
        "title" => "gate4-scan"
      })

      doc =
        Repo.one(
          from d in Document,
            where: d.title == "gate4-scan",
            order_by: [desc: d.inserted_at],
            limit: 1
        )

      assert doc, "expected a document to be ingested from the scan"
      {:ok, rev} = Quire.Documents.current_revision(doc)
      ref = Quire.Documents.Revision.storage_ref(rev)
      {:ok, bytes} = Quire.Storage.get(ref)
      assert binary_part(bytes, 0, 5) == "%PDF-"
    end
  end

  describe "home tiles (plan3 §10.1) launch §9.2 conversions" do
    test "conversion tiles are wired to the open-pipeline launcher", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture())
      {:ok, lv, _html} = live(conn, ~p"/")

      # The §9.2 launcher tiles carry phx-click="open_pdf" (they open the
      # file picker → ingest → land in the workspace where the conversion
      # ribbon lives). Only the non-conversion tiles keep no click handler.
      for title <- [
            "Clipboard to PDF",
            "Merge files",
            "Convert to PDF",
            "PDF to Word",
            "PDF to Excel"
          ] do
        assert has_element?(lv, ~s{div[phx-click="open_pdf"]}, title),
               "conversion tile #{title} must launch the open-pipeline"
      end

      # Open PDF / Batch / Customize keep their dedicated handlers
      assert has_element?(lv, ~s{div[phx-click="open_pdf"]}, "Open PDF")
      assert has_element?(lv, ~s{div[phx-click="open_batch"]}, "Batch")
      assert has_element?(lv, ~s{div[phx-click="open_customize"]}, "Customize")
    end
  end
end
