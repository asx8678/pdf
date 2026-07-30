defmodule Quire.Workers.RetentionWorkerTest do
  use Quire.DataCase, async: false

  alias Quire.Workers.RetentionWorker
  alias Quire.Documents.Revision
  alias Quire.Documents.Document
  alias Quire.Repo

  setup do
    user =
      %Quire.Accounts.User{
        id: Ecto.UUID.generate(),
        email: "user-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "x"
      }
      |> Repo.insert!()

    %{user: user}
  end

  defp document_fixture(user) do
    %Document{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      title: "test-retention.pdf"
    }
    |> Repo.insert!()
  end

  defp create_old_revision(document, days_ago) do
    old_time =
      DateTime.utc_now()
      |> DateTime.add(-days_ago * 86_400, :second)
      |> DateTime.truncate(:second)

    rev =
      %Revision{
        id: Ecto.UUID.generate(),
        document_id: document.id,
        label: "Revision #{days_ago}d ago",
        source: %{"storage_ref" => %{"byte_size" => 1024, "key" => "test/#{Ecto.UUID.generate()}"}}
      }
      |> Repo.insert!()

    # Override inserted_at (Ecto auto-generates timestamps on insert)
    Repo.update!(Ecto.Changeset.change(rev, inserted_at: old_time))
  end

  defp create_recent_revision(document) do
    %Revision{
      id: Ecto.UUID.generate(),
      document_id: document.id,
      label: "Recent revision",
      source: %{"storage_ref" => %{"byte_size" => 2048, "key" => "test/#{Ecto.UUID.generate()}"}}
    }
    |> Repo.insert!()
  end

  test "prunes revisions older than the retention period", %{user: user} do
    doc = document_fixture(user)

    old_rev = create_old_revision(doc, 40)
    current_rev = create_recent_revision(doc)
    doc |> Ecto.Changeset.change(%{current_revision_id: current_rev.id}) |> Repo.update!()

    assert :ok = RetentionWorker.perform(%Oban.Job{args: %{}})

    refute Repo.get(Revision, old_rev.id)
    assert Repo.get(Revision, current_rev.id)
  end

  test "never prunes the current revision of a document", %{user: user} do
    doc = document_fixture(user)

    rev = create_old_revision(doc, 90)
    doc |> Ecto.Changeset.change(%{current_revision_id: rev.id}) |> Repo.update!()

    assert :ok = RetentionWorker.perform(%Oban.Job{args: %{}})
    assert Repo.get(Revision, rev.id)
  end

  test "is idempotent - second run does not error", %{user: user} do
    doc = document_fixture(user)

    old_rev = create_old_revision(doc, 40)
    current_rev = create_recent_revision(doc)
    doc |> Ecto.Changeset.change(%{current_revision_id: current_rev.id}) |> Repo.update!()

    assert :ok = RetentionWorker.perform(%Oban.Job{args: %{}})
    refute Repo.get(Revision, old_rev.id)
    assert :ok = RetentionWorker.perform(%Oban.Job{args: %{}})
  end

  test "emits telemetry on prune", %{user: user} do
    doc = document_fixture(user)

    create_old_revision(doc, 40)
    current_rev = create_recent_revision(doc)
    doc |> Ecto.Changeset.change(%{current_revision_id: current_rev.id}) |> Repo.update!()

    test_ref = make_ref()
    :telemetry.attach_many(
      test_ref,
      [[:quire, :retention, :pruned]],
      fn event, measurements, _meta, _config ->
        send(self(), {event, measurements})
      end,
      nil
    )
    on_exit(fn -> :telemetry.detach(test_ref) end)

    assert :ok = RetentionWorker.perform(%Oban.Job{args: %{}})
    assert_receive {[:quire, :retention, :pruned], %{count: 1, reclaimed_bytes: 1024}}
  end

  test "does nothing when no revisions are old enough", %{user: user} do
    doc = document_fixture(user)

    rev = create_recent_revision(doc)
    doc |> Ecto.Changeset.change(%{current_revision_id: rev.id}) |> Repo.update!()

    assert :ok = RetentionWorker.perform(%Oban.Job{args: %{}})
    assert Repo.get(Revision, rev.id)
  end
end
