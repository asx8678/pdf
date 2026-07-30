defmodule Quire.Workers.EnvelopeReminderWorker do
  @moduledoc """
  Periodic worker that sends signing reminders for envelopes nearing
  expiry with outstanding signers.

  Runs hourly via the `maintenance` queue. Idempotent: uses a
  `last_reminded_at` threshold to avoid sending the same reminder twice
  in a 24-hour window.

  Only sends reminders for envelopes in `:sent` or `:partially_signed`
  status where at least one signer is still `:pending` or `:viewed`
  with an access token.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 2

  alias Quire.Repo
  alias Quire.Esign
  alias Quire.Esign.{Envelope, Signer}

  import Ecto.Query

  @reminder_window_days 7
  @min_hours_between_reminders 24

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    window_end = DateTime.add(now, @reminder_window_days * 24 * 60 * 60, :second)
    reminded_after = DateTime.add(now, -@min_hours_between_reminders * 60 * 60, :second)

    candidates =
      Repo.all(
        from(e in Envelope,
          where:
            e.status in [:sent, :partially_signed] and
              e.expires_at > ^now and
              e.expires_at < ^window_end and
              (is_nil(e.last_reminded_at) or e.last_reminded_at < ^reminded_after),
          preload: [:signers]
        )
      )

    Enum.each(candidates, fn envelope ->
      pending_signers =
        Enum.filter(envelope.signers, fn s ->
          s.status in [:pending, :viewed] and not is_nil(s.access_token)
        end)

      sent_any? =
        Enum.reduce_while(pending_signers, false, fn signer, _acc ->
          signing_url = signing_url_for(signer.access_token)

          case Quire.Esign.SignerNotifier.deliver_reminder(
                 signer.email,
                 signer.name,
                 envelope.subject,
                 "the sender",
                 signing_url
               ) do
            {:ok, _} -> {:cont, true}
            {:error, _} -> {:cont, true}
          end
        end)

      # Only bump last_reminded_at if we actually sent at least one email
      if sent_any? do
        envelope
        |> Envelope.changeset(%{})
        |> Ecto.Changeset.put_change(:last_reminded_at, now)
        |> Repo.update()
      end
    end)

    :ok
  end

  defp signing_url_for(token) when is_binary(token) do
    "/sign/#{token}"
  end

  defp signing_url_for(nil) do
    nil
  end
end
