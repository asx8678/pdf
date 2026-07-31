defmodule QuireWeb.WorkspaceLive.StampPlacementTest do
  use QuireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures, only: []

  alias Quire.Documents.{Document, Revision}
  alias Quire.Repo

  setup do
    user = user_fixture()
    doc = document_fixture(user)
    doc = revision_fixture(doc)
    %{user: user, doc: doc, conn: build_conn()}
  end

  describe "initials slot" do
    test "saves initials independently of the signature slot", %{user: user, doc: doc, conn: conn} do
      {:ok, lv, _html} = live_workspace(doc, conn)

      lv
      |> element(~s{button[phx-click="toggle_panel"][phx-value-item="initials"]})
      |> render_click()

      lv
      |> element("#sig-type-save")
      |> render_hook("save_initials", %{
        "label" => "My Initials",
        "type" => "type",
        "data" => Jason.encode!(%{text: "AB", font: "Alex Brush", size: 48})
      })

      # Saved to the initials slot, not signatures
      saved = Quire.Accounts.list_saved_initials(user.id)
      assert length(saved) == 1
      assert hd(saved)["label"] == "My Initials"
      assert Quire.Accounts.list_saved_signatures(user.id) == []

      assert has_element?(lv, ~s{[role="alert"]}, "Initials saved")
    end

    test "initials_use dispatches the saved initials to the client", %{
      user: user,
      doc: doc,
      conn: conn
    } do
      initials = %{
        "id" => Ecto.UUID.generate(),
        "label" => "AB",
        "type" => "type",
        "data" => Jason.encode!(%{text: "AB", font: "Alex Brush", size: 48}),
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      {:ok, _} =
        Quire.Accounts.update_user_settings(user.id, %{initials: %{initials["id"] => initials}})

      {:ok, lv, _html} = live_workspace(doc, conn)

      lv
      |> element(~s{button[phx-click="toggle_panel"][phx-value-item="initials"]})
      |> render_click()

      lv
      |> element(~s{button[phx-click="initials_use"][phx-value-id="#{initials["id"]}"]})
      |> render_click()

      assert_push_event(lv, "enable_signature_placement", %{signature: sent, kind: "initials"})
      assert sent["id"] == initials["id"]
    end

    test "delete_initials removes only the initials entry", %{user: user, doc: doc, conn: conn} do
      {:ok, _} =
        Quire.Accounts.update_user_settings(user.id, %{
          initials: %{
            "i1" => %{
              "id" => "i1",
              "label" => "A",
              "type" => "type",
              "data" => "{}",
              "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          },
          signatures: %{
            "s1" => %{
              "id" => "s1",
              "label" => "Sig",
              "type" => "draw",
              "data" => "{}",
              "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      {:ok, lv, _html} = live_workspace(doc, conn)

      lv
      |> element(~s{button[phx-click="toggle_panel"][phx-value-item="initials"]})
      |> render_click()

      lv
      |> element(~s{button[phx-click="delete_initials"][phx-value-id="i1"]})
      |> render_click()

      assert Quire.Accounts.list_saved_initials(user.id) == []
      assert length(Quire.Accounts.list_saved_signatures(user.id)) == 1
    end
  end

  describe "text stamps" do
    test "name_stamp_use dispatches the account name for placement", %{doc: doc, conn: conn} do
      {:ok, lv, _html} = live_workspace(doc, conn)

      lv
      |> element(~s{button[phx-click="toggle_panel"][phx-value-item="signatures"]})
      |> render_click()

      lv
      |> element(~s{button[phx-click="name_stamp_use"]})
      |> render_click()

      assert_push_event(lv, "enable_name_stamp_placement", %{text: text})
      assert is_binary(text) and text != ""
    end

    test "date_stamp_use uses the configured format", %{user: user, doc: doc, conn: conn} do
      {:ok, _} = Quire.Accounts.update_user_settings(user.id, %{signing_date_format: "%d %b %Y"})

      {:ok, lv, _html} = live_workspace(doc, conn)

      lv
      |> element(~s{button[phx-click="toggle_panel"][phx-value-item="signatures"]})
      |> render_click()

      lv
      |> element(~s{button[phx-click="date_stamp_use"]})
      |> render_click()

      assert_push_event(lv, "enable_date_stamp_placement", %{text: text})

      # Matches strftime "%d %b %Y" e.g. "31 Jul 2026"
      assert Regex.match?(~r/^\d{2} [A-Z][a-z]{2} \d{4}$/, text)
    end

    test "date_stamp_use falls back to ISO on a bad format", %{user: user, doc: doc, conn: conn} do
      {:ok, _} = Quire.Accounts.update_user_settings(user.id, %{signing_date_format: "%Q bad"})

      {:ok, lv, _html} = live_workspace(doc, conn)

      lv
      |> element(~s{button[phx-click="toggle_panel"][phx-value-item="signatures"]})
      |> render_click()

      lv
      |> element(~s{button[phx-click="date_stamp_use"]})
      |> render_click()

      assert_push_event(lv, "enable_date_stamp_placement", %{text: text})
      assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, text)
    end

    test "signature_placed journals a text-stamp kind", %{doc: doc, conn: conn} do
      {:ok, lv, _html} = live_workspace(doc, conn)
      png = File.read!(Path.expand("../../../fixtures/images/transparent.png", __DIR__))

      lv
      |> element("#document-canvas")
      |> render_hook("signature_placed", %{
        "page_index" => 0,
        "rect" => [72.0, 72.0, 220.0, 90.0],
        "png" => Base.encode64(png),
        "kind" => "date"
      })

      assert_push_event(lv, "open_document", %{url: url, password: nil})
      assert url == "/documents/#{doc.id}/pdf"

      # Journal op recorded the kind
      updated = Repo.get!(Document, doc.id)
      assert updated.current_revision_id != doc.current_revision_id

      rev = Repo.get!(Revision, updated.current_revision_id)
      ref = Quire.Documents.Revision.storage_ref(rev)
      assert {:ok, bytes} = Quire.Storage.get(ref)
      assert {:ok, _} = Quire.Pdf.open(bytes)
      assert {:ok, render_ref} = Quire.Storage.put(bytes, name: "stamp.pdf")
      assert {:ok, _png} = Quire.Render.Pdfium.render_page(render_ref, 0, dpi: 72)
    end
  end

  defp live_workspace(doc, conn) do
    {:ok, conn} = {:ok, log_in_user(conn, Quire.Repo.get!(Quire.Accounts.User, doc.user_id))}
    live(conn, ~p"/workspace/#{doc.id}")
  end

  defp user_fixture do
    %Quire.Accounts.User{
      id: Ecto.UUID.generate(),
      email: "user-#{System.unique_integer([:positive])}@example.com",
      hashed_password: "x"
    }
    |> Quire.Repo.insert!()
  end

  defp document_fixture(user) do
    %Document{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      title: "stamp-test.pdf"
    }
    |> Quire.Repo.insert!()
  end

  defp revision_fixture(doc) do
    # PDFium-generated bytes (lopdf-parseable — see signature_flatten_test)
    {:ok, ex_doc} =
      ExPdfium.open(File.read!(Path.expand("../../../fixtures/pdfs/simple_text.pdf", __DIR__)))

    {:ok, pdf} = ExPdfium.save_to_bytes(ex_doc)
    {:ok, ref} = Quire.Storage.put(pdf, name: "stamp-test.pdf", content_type: "application/pdf")

    source = %{
      "storage_ref" => %{
        "adapter" => to_string(ref.adapter),
        "key" => ref.key,
        "name" => ref.name,
        "content_type" => ref.content_type,
        "byte_size" => ref.byte_size
      },
      "filename" => "stamp-test.pdf"
    }

    {:ok, rev} = Quire.Documents.create_revision(doc, label: "v1", source: source)

    {:ok, updated} =
      doc
      |> Ecto.Changeset.change(%{current_revision_id: rev.id, page_count: 1})
      |> Quire.Repo.update()

    updated
  end
end
