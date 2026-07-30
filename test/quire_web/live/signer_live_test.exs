defmodule QuireWeb.SignerLiveTest do
  use QuireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Quire.Esign.{Envelope, Signer}
  alias Quire.Repo

  setup do
    user = user_fixture()
    doc = document_fixture(user)
    envelope = envelope_fixture(%{owner_id: user.id, document_id: doc.id, status: :sent})
    signer = signer_fixture(%{envelope_id: envelope.id, access_token: "test-token-123"})

    %{user: user, doc: doc, envelope: envelope, signer: signer, token: "test-token-123"}
  end

  describe "public signer page" do
    test "renders identity confirmation when token is valid", %{conn: conn, token: token} do
      {:ok, _view, html} = live(conn, ~p"/sign/#{token}")

      assert html =~ "Confirm Your Identity"
      assert html =~ "Test Signer"
      assert html =~ "signer@example.com"
    end

    test "shows error for invalid token", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sign/invalid-token")

      assert html =~ "Invalid signing link"
    end

    test "shows error for already used token", %{conn: conn} do
      signer = Repo.get_by!(Signer, access_token: "test-token-123")

      signer
      |> Signer.changeset(%{})
      |> Signer.put_status(:viewed)
      |> Repo.update!()
      |> then(fn s ->
        s
        |> Signer.changeset(%{})
        |> Signer.put_status(:signed)
        |> Repo.update!()
      end)

      {:ok, _view, html} = live(conn, ~p"/sign/test-token-123")

      assert html =~ "already been used"
    end

    test "shows error for expired envelope", %{conn: conn, envelope: envelope} do
      envelope
      |> Envelope.changeset(%{})
      |> Envelope.put_status(:expired)
      |> Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/sign/test-token-123")

      assert html =~ "expired"
    end

    test "transitions through all steps", %{conn: conn, token: token} do
      {:ok, view, html} = live(conn, ~p"/sign/#{token}")

      assert html =~ "Confirm Your Identity"
      render_click(view, "go_to_consent")

      html = render(view)
      assert html =~ "Consent to Electronic Signature"
      render_click(view, "consent_and_review")

      html = render(view)
      assert html =~ "Review Document"
      render_click(view, "proceed_to_sign")

      html = render(view)
      assert html =~ "Sign Document"
    end

    test "declining from confirm step shows receipt", %{conn: conn, token: token} do
      {:ok, view, html} = live(conn, ~p"/sign/#{token}")

      assert html =~ "Confirm Your Identity"
      render_click(view, "decline")

      html = render(view)
      assert html =~ "Request Declined"
    end

    test "signing the document marks it complete", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/sign/#{token}")

      render_click(view, "go_to_consent")
      render_click(view, "consent_and_review")
      render_click(view, "proceed_to_sign")
      render_click(view, "sign_document")

      html = render(view)
      assert html =~ "applied successfully"

      signer = Repo.get_by!(Signer, access_token: "test-token-123")
      assert signer.status == :signed

      events = Quire.Esign.list_audit_events(Repo.get!(Envelope, signer.envelope_id))
      assert Enum.any?(events, &(&1.event == "signed"))
    end
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
    %Quire.Documents.Document{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      title: "test.pdf"
    }
    |> Quire.Repo.insert!()
  end

  defp envelope_fixture(attrs) do
    {status, attrs} = Map.pop(attrs, :status, :draft)

    %Envelope{
      id: Ecto.UUID.generate(),
      subject: "Please sign this",
      status: :draft,
      signing_mode: :sequential
    }
    |> Envelope.changeset(attrs)
    |> Envelope.put_status(status)
    |> Quire.Repo.insert!()
  end

  defp signer_fixture(attrs) do
    %Signer{
      name: "Test Signer",
      email: "signer@example.com",
      order: 1,
      status: :pending,
      access_token: Ecto.UUID.generate()
    }
    |> Signer.changeset(attrs)
    |> Quire.Repo.insert!()
  end
end
