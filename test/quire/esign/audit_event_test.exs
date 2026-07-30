defmodule Quire.Esign.AuditEventTest do
  use Quire.DataCase, async: false

  alias Quire.Esign
  alias Quire.Esign.{Envelope, Signer, AuditEvent}

  setup do
    user = user_fixture()
    doc = document_fixture(user)
    %{user: user, doc: doc}
  end

  describe "record_audit_event/3" do
    test "records an event for the envelope", %{user: user, doc: doc} do
      envelope = insert_envelope(%{owner_id: user.id, document_id: doc.id})
      assert {:ok, event} = Esign.record_audit_event(envelope, "envelope_created")

      assert event.event == "envelope_created"
      assert event.envelope_id == envelope.id
      assert event.signer_id == nil
    end
  end

  describe "record_audit_event/4" do
    test "records an event for a specific signer", %{user: user, doc: doc} do
      envelope = insert_envelope(%{owner_id: user.id, document_id: doc.id})
      signer = insert_signer(envelope, %{})

      assert {:ok, event} =
               Esign.record_audit_event(envelope, signer, "signer_viewed", %{"ip" => "127.0.0.1"})

      assert event.event == "signer_viewed"
      assert event.envelope_id == envelope.id
      assert event.signer_id == signer.id
      assert event.metadata["ip"] == "127.0.0.1"
    end

    test "accepts atom event names", %{user: user, doc: doc} do
      envelope = insert_envelope(%{owner_id: user.id, document_id: doc.id})
      assert {:ok, event} = Esign.record_audit_event(envelope, :envelope_sent)
      assert event.event == "envelope_sent"
    end
  end

  describe "list_audit_events/1" do
    test "returns chronological events", %{user: user, doc: doc} do
      envelope = insert_envelope(%{owner_id: user.id, document_id: doc.id})
      {:ok, _e1} = Esign.record_audit_event(envelope, "envelope_created")
      {:ok, _e2} = Esign.record_audit_event(envelope, "envelope_sent")

      events = Esign.list_audit_events(envelope)
      assert length(events) == 2
    end

    test "returns empty list when no events exist", %{user: user, doc: doc} do
      envelope = insert_envelope(%{owner_id: user.id, document_id: doc.id})
      assert Esign.list_audit_events(envelope) == []
    end
  end

  describe "send_envelope records audit event" do
    test "creates envelope_sent event on send", %{user: user, doc: doc} do
      envelope = insert_draft_envelope(%{owner_id: user.id, document_id: doc.id})

      signers = [
        insert_signer(envelope, %{name: "A", email: "a@b.com", order: 1}),
        insert_signer(envelope, %{name: "B", email: "c@d.com", order: 2})
      ]

      Esign.send_envelope(envelope)

      events = Esign.list_audit_events(envelope)
      assert Enum.any?(events, &(&1.event == "envelope_sent"))
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

  defp insert_envelope(attrs) do
    %Envelope{
      id: Ecto.UUID.generate(),
      subject: "Please sign",
      status: :draft,
      signing_mode: :sequential
    }
    |> Envelope.changeset(attrs)
    |> Quire.Repo.insert!()
  end

  defp insert_draft_envelope(attrs) do
    insert_envelope(attrs)
  end

  defp insert_signer(envelope, attrs) do
    %Signer{
      envelope_id: envelope.id,
      name: "Signer",
      email: "signer@example.com",
      order: 1,
      status: :pending,
      access_token: Ecto.UUID.generate()
    }
    |> Signer.changeset(attrs)
    |> Quire.Repo.insert!()
  end
end
