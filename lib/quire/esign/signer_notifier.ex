defmodule Quire.Esign.SignerNotifier do
  @moduledoc """
  Email notifications for envelope lifecycle events.

  Generates Swoosh emails for invitation, reminder, completion, and
  decline events. The signer's access URL is supplied by the caller
  and typically built via the application `url/1` helper so it resolves
  through the configured host/port.
  """

  import Swoosh.Email

  alias Quire.Mailer

  @doc """
  Sends an envelope invitation to a signer.
  """
  def deliver_invitation(
        recipient_email,
        recipient_name,
        envelope_subject,
        owner_name,
        signing_url
      ) do
    subject = "Please sign: #{envelope_subject || "Document"}"

    body = """
    #{recipient_name},

    #{owner_name || "Someone"} has sent you a document to sign.

    Subject: #{envelope_subject}

    #{signing_url}

    If you weren't expecting this invitation, please ignore this email.
    """

    deliver(recipient_email, subject, body)
  end

  @doc """
  Sends a reminder to a signer who hasn't signed yet.
  """
  def deliver_reminder(recipient_email, recipient_name, envelope_subject, owner_name, signing_url) do
    subject = "Reminder: #{envelope_subject || "Document"} still needs your signature"

    body = """
    Hi #{recipient_name},

    This is a reminder that #{owner_name || "someone"} is waiting
    for your signature on \"#{envelope_subject}\".

    Sign here: #{signing_url}

    If the envelope has expired or you no longer need to sign, you can
    safely ignore this reminder.
    """

    deliver(recipient_email, subject, body)
  end

  @doc """
  Notifies the envelope owner that all signers have completed.
  """
  def deliver_completion(owner_email, owner_name, envelope_subject) do
    subject = "All signatures collected for: #{envelope_subject || "Document"}"

    body = """
    #{owner_name},

    All signers have completed \"#{envelope_subject}\" successfully.

    The signed document is available in your account.
    """

    deliver(owner_email, subject, body)
  end

  @doc """
  Notifies the envelope owner that a signer has declined.
  """
  def deliver_decline(owner_email, owner_name, envelope_subject, signer_name) do
    subject = "#{signer_name} declined: #{envelope_subject || "Document"}"

    body = """
    #{owner_name},

    #{signer_name} has declined to sign \"#{envelope_subject}\".

    You may want to contact them directly or void the envelope if
    signatures are no longer needed.
    """

    deliver(owner_email, subject, body)
  end

  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Quire", "noreply@quire.app"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end
end
