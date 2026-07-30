defmodule Quire.Esign do
  @moduledoc """
  The E-Sign context — multi-party signature envelope workflow (§9.9).

  Manages the envelope state machine, signer lifecycle, and field placement.
  """

  import Ecto.Query, warn: false

  alias Quire.Repo
  alias Quire.Esign.{Envelope, Signer, Field}

  @doc """
  Creates a new envelope from the given attrs.

  Supports the fields: `document_id`, `owner_id`, `subject`, `message`, `expires_at`.
  New envelopes start in `:draft` status.
  """
  def create_envelope(attrs \\ %{}) do
    %Envelope{}
    |> Envelope.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Sends an envelope, transitioning it from `:draft` to `:sent`.

  Returns `{:error, reason}` if the envelope is not in draft status.
  """
  def send_envelope(%Envelope{status: :draft} = envelope, attrs \\ %{}) do
    changeset =
      envelope
      |> Envelope.changeset(attrs)
      |> Envelope.put_status(:sent)
      |> Envelope.put_sent_at()

    Repo.update(changeset)
  end

  def send_envelope(%Envelope{} = _envelope, _attrs) do
    {:error, :invalid_transition}
  end

  @doc """
  Marks a signer as having viewed the document.
  """
  def record_signer_view(%Signer{} = signer) do
    signer
    |> Signer.changeset(%{})
    |> Signer.put_status(:viewed)
    |> Repo.update()
  end

  @doc """
  Signs the envelope on behalf of a signer.

  Updates the signer's status to `:signed` and checks whether all signers
  have signed. If the final signer signs, the envelope transitions to
  `:completed`.
  """
  def sign_envelope(%Envelope{status: status} = envelope, %Signer{} = signer, attrs \\ %{}) do
    with :ok <- verify_signing_state(status, signer.status),
         :ok <- verify_signing_order(signer, list_signers(envelope), envelope.signing_mode || :sequential),
         {:ok, updated_signer} <- do_sign_signer(signer, attrs),
         :ok <- maybe_complete_envelope(envelope, updated_signer) do
      {:ok, updated_signer}
    end
  end

  defp verify_signing_state(:sent, :viewed), do: :ok
  defp verify_signing_state(:sent, :pending), do: {:error, :signer_not_viewed_yet}
  defp verify_signing_state(:draft, _), do: {:error, :envelope_not_sent}
  defp verify_signing_state(:completed, _), do: {:error, :envelope_already_completed}
  defp verify_signing_state(:declined, _), do: {:error, :envelope_declined}
  defp verify_signing_state(:voided, _), do: {:error, :envelope_voided}
  defp verify_signing_state(:expired, _), do: {:error, :envelope_expired}
  defp verify_signing_state(_, :signed), do: {:error, :already_signed}
  defp verify_signing_state(_, :declined), do: {:error, :already_declined}
  defp verify_signing_state(_, _), do: {:error, :invalid_transition}

  @doc """
  Checks whether a signer's access token is active for the signing flow.

  In parallel mode, all signers can access immediately.
  In sequential mode, only the lowest-ordered unsigned signer can access.
  """
  def can_signer_access?(envelope, signer) do
    if (envelope.signing_mode || :sequential) == :parallel do
      true
    else
      is_next_signer?(signer, list_signers(envelope))
    end
  end

  @doc """
  Checks that the signer is allowed to sign based on the signing order.

  Takes a list of all signers ordered by their `order` field.

  In parallel mode, any signer may sign (no order restriction).
  In sequential mode, only the lowest-ordered unsigned signer may sign.
  """
  def verify_signing_order(signer, signers, mode)

  def verify_signing_order(_signer, _signers, :parallel), do: :ok
  def verify_signing_order(signer, signers, :sequential) do
    if is_next_signer?(signer, signers) do
      :ok
    else
      {:error, :signer_out_of_order}
    end
  end

  defp is_next_signer?(signer, signers) do
    next = Enum.find(signers, fn s -> s.status not in [:signed, :declined] end)
    next != nil and next.id == signer.id
  end

  defp do_sign_signer(signer, attrs) do
    now = DateTime.utc_now(:second)

    signer
    |> Signer.changeset(attrs)
    |> Signer.put_status(:signed)
    |> Signer.put_signed_at(now)
    |> Repo.update()
  end

  defp maybe_complete_envelope(envelope, _signed_signer) do
    remaining_unsigned = get_unsigned_signers_count(envelope.id)

    if remaining_unsigned == 0 do
      now = DateTime.utc_now(:second)

      envelope
      |> Envelope.changeset(%{})
      |> Envelope.put_status(:completed)
      |> Envelope.put_completed_at()
      |> Repo.update()
    else
      # Not all signers have signed yet — check if status needs
      # to be updated to :partially_signed
      if envelope.status == :sent do
        envelope
        |> Envelope.changeset(%{})
        |> Envelope.put_status(:partially_signed)
        |> Repo.update()
      end

      :ok
    end
  end

  defp get_unsigned_signers_count(envelope_id) do
    import Ecto.Query

    Repo.one!(
      from(s in Signer,
        where: s.envelope_id == ^envelope_id and s.status not in [:signed, :declined],
        select: count(s.id)
      )
    )
  end

  @doc """
  Declines the envelope on behalf of a signer.
  """
  def decline_envelope(%Envelope{status: :sent} = envelope, %Signer{status: :pending} = signer, attrs \\ %{}) do
    signer
    |> Signer.changeset(attrs)
    |> Signer.put_status(:declined)
    |> Repo.update()
    |> case do
      {:ok, updated_signer} ->
        envelope
        |> Envelope.changeset(%{})
        |> Envelope.put_status(:declined)
        |> Repo.update()
        {:ok, updated_signer}
      error -> error
    end
  end

  def decline_envelope(%Envelope{} = _envelope, %Signer{} = _signer, _attrs) do
    {:error, :invalid_transition}
  end

  @doc """
  Voids an envelope.  Only envelopes in `:sent` or `:partially_signed` status
  can be voided.
  """
  def void_envelope(%Envelope{status: status} = envelope) when status in [:sent, :partially_signed] do
    envelope
    |> Envelope.changeset(%{})
    |> Envelope.put_status(:voided)
    |> Repo.update()
  end

  def void_envelope(%Envelope{} = _envelope) do
    {:error, :invalid_transition}
  end

  @doc """
  Marks an expired envelope.  Called by a periodic job.
  """
  def expire_envelope(%Envelope{status: status} = envelope) when status in [:sent, :partially_signed] do
    envelope
    |> Envelope.changeset(%{})
    |> Envelope.put_status(:expired)
    |> Repo.update()
  end

  def expire_envelope(%Envelope{} = _envelope) do
    {:error, :invalid_transition}
  end

  @doc """
  Adds a signer to an envelope.
  """
  def add_signer(%Envelope{status: :draft} = envelope, attrs) do
    %Signer{envelope_id: envelope.id}
    |> Signer.changeset(attrs)
    |> Repo.insert()
  end

  def add_signer(%Envelope{} = _envelope, _attrs) do
    {:error, :envelope_not_in_draft}
  end

  @doc """
  Adds a field to an envelope for a specific signer.
  """
  def add_field(%Envelope{status: :draft} = _envelope, signer, attrs) do
    %Field{envelope_id: signer.envelope_id, signer_id: signer.id}
    |> Field.changeset(attrs)
    |> Repo.insert()
  end

  def add_field(%Envelope{} = _envelope, _signer, _attrs) do
    {:error, :envelope_not_in_draft}
  end

  @doc """
  Gets an envelope by ID.
  """
  def get_envelope!(id) do
    Repo.get!(Envelope, id)
  end

  @doc """
  Lists signers for an envelope, ordered by their `:order` field.
  """
  def list_signers(%Envelope{id: envelope_id}) do
    Repo.all(
      from(s in Signer,
        where: s.envelope_id == ^envelope_id,
        order_by: s.order
      )
    )
  end

  @doc """
  Lists fields for an envelope.
  """
  def list_fields(%Envelope{id: envelope_id}) do
    Repo.all(
      from(f in Field,
        where: f.envelope_id == ^envelope_id,
        order_by: f.page_index
      )
    )
  end
end
