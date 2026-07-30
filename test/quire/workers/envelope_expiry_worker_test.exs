defmodule Quire.Workers.EnvelopeExpiryWorkerTest do
  use Quire.DataCase, async: false

  alias Quire.Workers.EnvelopeExpiryWorker
  alias Quire.Esign.Envelope

  setup do
    user = user_fixture()
    doc = document_fixture(user)
    %{user: user, doc: doc}
  end

  test "expires envelopes past their expires_at", %{user: user, doc: doc} do
    past = DateTime.add(DateTime.utc_now(), -3600, :second)

    expired_env =
      envelope_fixture(%{
        owner_id: user.id,
        document_id: doc.id,
        status: :sent,
        expires_at: past
      })

    future = DateTime.add(DateTime.utc_now(), 7200, :second)

    _not_expired =
      envelope_fixture(%{
        owner_id: user.id,
        document_id: doc.id,
        status: :sent,
        expires_at: future
      })

    assert :ok = EnvelopeExpiryWorker.perform(%Oban.Job{args: %{}})

    expired = Quire.Repo.get(Envelope, expired_env.id)
    assert expired.status == :expired
  end

  test "is idempotent — second run does not error", %{user: user, doc: doc} do
    past = DateTime.add(DateTime.utc_now(), -3600, :second)

    envelope_fixture(%{
      owner_id: user.id,
      document_id: doc.id,
      status: :sent,
      expires_at: past
    })

    assert :ok = EnvelopeExpiryWorker.perform(%Oban.Job{args: %{}})
    assert :ok = EnvelopeExpiryWorker.perform(%Oban.Job{args: %{}})
  end

  test "does not touch draft envelopes", %{user: user, doc: doc} do
    past = DateTime.add(DateTime.utc_now(), -3600, :second)

    env =
      envelope_fixture(%{
        owner_id: user.id,
        document_id: doc.id,
        status: :draft,
        expires_at: past
      })

    assert :ok = EnvelopeExpiryWorker.perform(%Oban.Job{args: %{}})

    draft = Quire.Repo.reload!(env)
    assert draft.status == :draft
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
end
