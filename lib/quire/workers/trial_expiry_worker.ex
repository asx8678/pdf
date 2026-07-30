defmodule Quire.Workers.TrialExpiryWorker do
  @moduledoc """
  Scheduled worker that downgrades expired trial licenses to the
  `"standard"` tier.

  Runs daily via the `maintenance` queue (`@daily` cron schedule).
  Idempotent: updating an already-expired license is a no-cost no-op.

  The `expires_at` threshold is `now()` — any trial license whose expiry
  has passed is downgraded. Workers that find nothing to do exit early.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Quire.Repo

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(l in Quire.Accounts.License,
          where: l.tier == "trial" and l.expires_at < ^now
        ),
        set: [tier: "standard"]
      )

    if count > 0 do
      require Logger
      Logger.info("TrialExpiryWorker: downgraded #{count} expired trial license(s)")
    end

    :ok
  end
end
