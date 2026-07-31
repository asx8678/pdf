defmodule QuireWeb.WorkspaceLiveScanTest do
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures
  import Ecto.Query

  alias Quire.Repo
  alias Quire.Documents.Document

  @scan_btn ~s{button[phx-click="open_camera_capture"]}
  @dialog ~s{div[role="dialog"][aria-label="Scan to PDF"]}

  defp open_workspace(conn) do
    conn
    |> log_in_user(user_fixture())
    |> live(~p"/workspace/doc-1")
  end

  defp png_data_url(width \\ 64, height \\ 48) do
    {:ok, black} = Vix.Vips.Operation.black(width, height)
    {:ok, png} = Vix.Vips.Image.write_to_buffer(black, ".png")
    "data:image/png;base64," <> Base.encode64(png)
  end

  describe "scan to PDF (T-080)" do
    test "Scan ribbon button opens the modal with the scan options and both capture paths", %{
      conn: conn
    } do
      {:ok, lv, _html} = open_workspace(conn)

      lv |> element(@scan_btn) |> render_click()

      assert has_element?(lv, @dialog)
      # deskew toggle, contrast preset select, OCR toggle
      assert has_element?(lv, "#scan-deskew-camera-capture[checked]")
      assert has_element?(lv, "#scan-contrast-camera-capture option[value='auto'][selected]")
      assert has_element?(lv, "#scan-ocr-camera-capture")
      # WebRTC camera component + file input with camera capture
      assert has_element?(lv, ~s{button[phx-click="camera_requested"]})
      assert has_element?(lv, "#scan-file-input-camera-capture[capture='environment']")
      assert has_element?(lv, ~s{button[phx-click="use_file_source"]})
    end

    test "file input path creates a new PDF document via Quire.Scan", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      lv |> element(@scan_btn) |> render_click()

      assert_redirect =
        render_hook(lv, "scan_file_ready", %{
          "dataUrl" => png_data_url(),
          "deskew" => "true",
          "contrast" => "auto",
          "ocr" => "false",
          "title" => "scan-live-test"
        })

      assert assert_redirect != nil

      doc =
        Repo.one(
          from d in Document,
            where: d.title == "scan-live-test",
            order_by: [desc: d.inserted_at],
            limit: 1
        )

      assert doc, "expected a document to be ingested from the scan"

      # The ingested PDF is a real single-page PDF
      {:ok, rev} = Quire.Documents.current_revision(doc)
      assert rev.source["storage_ref"]["content_type"] == "application/pdf"

      ref = Quire.Documents.Revision.storage_ref(rev)
      {:ok, bytes} = Quire.Storage.get(ref)
      assert binary_part(bytes, 0, 5) == "%PDF-"
    end

    test "deskew/contrast/ocr option toggles update the component state", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      lv |> element(@scan_btn) |> render_click()

      # Deskew default on; toggle off
      assert has_element?(lv, "#scan-deskew-camera-capture[checked]")
      lv |> element("#scan-deskew-camera-capture") |> render_click()
      refute has_element?(lv, "#scan-deskew-camera-capture[checked]")

      # Contrast select change
      lv
      |> element("#scan-contrast-camera-capture")
      |> render_change(%{"contrast" => "bw"})

      assert has_element?(lv, "#scan-contrast-camera-capture option[value='bw'][selected]")

      # OCR toggle
      lv |> element("#scan-ocr-camera-capture") |> render_click()
      assert has_element?(lv, "#scan-ocr-camera-capture[checked]")
    end

    test "rejects invalid image bytes with a plain-language flash", %{conn: conn} do
      {:ok, lv, _html} = open_workspace(conn)

      lv |> element(@scan_btn) |> render_click()

      lv
      |> render_hook("scan_file_ready", %{
        "dataUrl" => "data:image/png;base64," <> Base.encode64(<<"not an image">>),
        "deskew" => "true",
        "contrast" => "auto",
        "ocr" => "false",
        "title" => "bad-scan"
      })

      assert has_element?(lv, ~s{div[role="alert"]})
    end
  end
end
