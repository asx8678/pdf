defmodule Quire.Workers.EnvelopeReminderWorkerTest do
  use Quire.DataCase, async: false

  alias Quire.Workers.EnvelopeReminderWorker
  alias Quire.Esign.{Envelope, Signer}

  setup do
    user = user_fixture()
    doc = document_fixture(user)

    envelope =
      envelope_fixture(%{
        owner_id: user.id,
        document_id: doc.id,
        status: :sent,
        expires_at: DateTime.add(DateTime.utc_now(), 3 * 24 * 3600, :second)
      })

    signer =
      signer_fixture(%{
        envelope_id: envelope.id,
        status: :pending,
        access_token: Ecto.UUID.generate()
      })

    %{user: user, doc: doc, envelope: envelope, signer: signer}
  end

  test "sends reminders for pending signers on expiring envelopes", %{
    envelope: envelope,
    signer: _signer
  } do
    assert :ok = EnvelopeReminderWorker.perform(%Oban.Job{args: %{}})

    updated = Quire.Repo.reload!(envelope)
    assert updated.last_reminded_at != nil
  end

  test "does not send if already reminded recently", %{envelope: envelope, signer: _signer} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    envelope
    |> Ecto.Changeset.change(last_reminded_at: now)
    |> Quire.Repo.update!()

    assert :ok = EnvelopeReminderWorker.perform(%Oban.Job{args: %{}})

    updated = Quire.Repo.reload!(envelope)
    assert DateTime.compare(updated.last_reminded_at, now) == :eq
  end

  test "skips envelopes outside the reminder window", %{user: user, doc: doc} do
    far_future =
      envelope_fixture(%{
        owner_id: user.id,
        document_id: doc.id,
        status: :sent,
        expires_at: DateTime.add(DateTime.utc_now(), 30 * 24 * 3600, :second)
      })

    signer_fixture(%{
      envelope_id: far_future.id,
      status: :pending,
      access_token: Ecto.UUID.generate()
    })

    assert :ok = EnvelopeReminderWorker.perform(%Oban.Job{args: %{}})

    updated = Quire.Repo.reload!(far_future)
    assert updated.last_reminded_at == nil
  end

  test "skips signers without access tokens", %{user: user, doc: doc} do
    envelope =
      envelope_fixture(%{
        owner_id: user.id,
        document_id: doc.id,
        status: :sent,
        expires_at: DateTime.add(DateTime.utc_now(), 3 * 24 * 3600, :second)
      })

    signer_fixture(%{envelope_id: envelope.id, status: :pending, access_token: nil})

    assert :ok = EnvelopeReminderWorker.perform(%Oban.Job{args: %{}})

    updated = Quire.Repo.reload!(envelope)
    assert updated.last_reminded_at == nil
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
      subject: "Please sign",
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
