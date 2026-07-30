defmodule Quire.Workers.EnvelopeExpiryWorker do
  @moduledoc """
  Periodic worker that transitions envelopes past their `expires_at` to
  `:expired` status.

  Runs hourly via the `maintenance` queue. Idempotent: querying for
  sent/partially_signed envelopes with `expires_at < now()` will only
  find envelopes that haven't been expired yet.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 2

  alias Quire.Repo
  alias Quire.Esign
  alias Quire.Esign.Envelope

  import Ecto.Query

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    expired_envelopes =
      Repo.all(
        from(e in Envelope,
          where: e.status in [:sent, :partially_signed] and e.expires_at < ^now
        )
      )

    Enum.each(expired_envelopes, fn envelope ->
      case Esign.expire_envelope(envelope) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          require Logger

          Logger.warning(
            "EnvelopeExpiryWorker: failed to expire #{envelope.id}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end
end
