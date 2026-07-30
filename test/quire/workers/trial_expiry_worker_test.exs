defmodule Quire.Workers.TrialExpiryWorkerTest do
  use Quire.DataCase, async: true

  alias Quire.Workers.TrialExpiryWorker
  alias Quire.Accounts.License

  describe "perform/1" do
    test "downgrades expired trial licenses to standard" do
      insert_license(%{tier: "trial", expires_at: ~U[2025-01-01 00:00:00Z]})
      insert_license(%{tier: "trial", expires_at: ~U[2025-06-15 12:00:00Z]})

      assert :ok = TrialExpiryWorker.perform(%Oban.Job{args: %{}})

      remaining_trials =
        Quire.Repo.one(from(l in License, where: l.tier == "trial", select: count(l.id)))

      assert remaining_trials == 0

      standards =
        Quire.Repo.one(from(l in License, where: l.tier == "standard", select: count(l.id)))

      assert standards == 2
    end

    test "does not downgrade unexpired trial licenses" do
      insert_license(%{tier: "trial", expires_at: nil})
      insert_license(%{tier: "trial", expires_at: ~U[2099-01-01 00:00:00Z]})

      assert :ok = TrialExpiryWorker.perform(%Oban.Job{args: %{}})

      remaining_trials =
        Quire.Repo.one(from(l in License, where: l.tier == "trial", select: count(l.id)))

      assert remaining_trials == 2
    end

    test "does not affect non-trial licenses" do
      insert_license(%{tier: "premium", expires_at: ~U[2025-01-01 00:00:00Z]})

      assert :ok = TrialExpiryWorker.perform(%Oban.Job{args: %{}})

      premium =
        Quire.Repo.one(from(l in License, where: l.tier == "premium", select: count(l.id)))

      assert premium == 1
    end

    test "succeeds when no licenses exist" do
      assert :ok = TrialExpiryWorker.perform(%Oban.Job{args: %{}})
    end
  end

  defp insert_user do
    %Quire.Accounts.User{
      id: Ecto.UUID.generate(),
      email: "trial-test-#{System.unique_integer([:positive])}@example.com",
      hashed_password: "unused"
    }
    |> Quire.Repo.insert!()
  end

  defp insert_license(attrs) do
    user = insert_user()

    %License{
      user_id: user.id,
      tier: "trial",
      seats: 1
    }
    |> License.changeset(attrs)
    |> Quire.Repo.insert!()
  end
end
