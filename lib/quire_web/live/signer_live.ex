defmodule QuireWeb.SignerLive do
  @moduledoc """
  Public LiveView for the signer signing flow (§9.9).
  """

  use QuireWeb, :live_view

  alias Quire.Esign
  alias Quire.Esign.{Signer, Envelope}

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Esign.get_signer_by_token(token) do
      {:ok, signer} ->
        if signer.status in [:pending, :viewed] do
          envelope = Esign.get_envelope!(signer.envelope_id)

          if envelope.status in [:sent, :partially_signed] do
            fields = Esign.list_fields(envelope)
            signers = Esign.list_signers(envelope)

            socket =
              socket
              |> assign(:page_title, "Sign: #{envelope.subject || "Document"}")
              |> assign(:signer, signer)
              |> assign(:envelope, envelope)
              |> assign(:fields, fields)
              |> assign(:signers, signers)
              |> assign(:step, :confirm)
              |> assign(:error, nil)
              |> assign(:token, token)
              |> assign(:signing_successful, false)
              |> assign(:declined, false)

            {:ok, socket}
          else
            {:ok, assign_error(socket, "This signing request has expired or been completed.")}
          end
        else
          {:ok, assign_error(socket, "This signing link has already been used.")}
        end

      {:error, :not_found} ->
        {:ok, assign_error(socket, "Invalid signing link. Please check the link and try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50 dark:bg-gray-900">
      <div class="max-w-3xl mx-auto px-4 py-8">
        <div class="text-center mb-8">
          <h1 class="text-2xl font-bold text-gray-900 dark:text-gray-100">
            Sign Document
          </h1>
          <p class="text-sm text-gray-500 dark:text-gray-400">
            {@envelope.subject || "Document to sign"}
          </p>
        </div>

        <%= if @error do %>
          <div class="bg-red-50 dark:bg-red-900/30 border border-red-200 dark:border-red-800 rounded-xl p-6 text-center">
            <p class="text-lg font-medium text-red-800 dark:text-red-200">{@error}</p>
          </div>
        <% else %>
          <div class="bg-white dark:bg-gray-800 rounded-xl shadow-sm border border-gray-200 dark:border-gray-700 p-6">
            <%= case @step do %>
              <% :confirm -> %>
                <h2 class="text-lg font-semibold mb-4">Confirm Your Identity</h2>
                <p class="text-sm text-gray-500 mb-6">
                  Please confirm your details before proceeding
                </p>

                <div class="space-y-4 mb-6">
                  <div class="flex items-center justify-between p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                    <span class="text-sm text-gray-500 dark:text-gray-400">Name</span>
                    <span class="font-medium text-gray-900 dark:text-gray-100">{@signer.name}</span>
                  </div>
                  <div class="flex items-center justify-between p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                    <span class="text-sm text-gray-500 dark:text-gray-400">Email</span>
                    <span class="font-medium text-gray-900 dark:text-gray-100">{@signer.email}</span>
                  </div>
                  <div class="flex items-center justify-between p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                    <span class="text-sm text-gray-500 dark:text-gray-400">Document</span>
                    <span class="font-medium text-gray-900 dark:text-gray-100">{@envelope.subject ||
                      "Untitled"}</span>
                  </div>
                  <%= if @envelope.message do %>
                    <div class="p-3 bg-blue-50 dark:bg-blue-900/20 rounded-lg">
                      <p class="text-sm text-blue-800 dark:text-blue-200">{@envelope.message}</p>
                    </div>
                  <% end %>
                </div>

                <div class="flex gap-3">
                  <button
                    type="button"
                    phx-click="go_to_consent"
                    class="flex-1 justify-center inline-flex items-center rounded-lg bg-accent px-4 py-2 text-sm font-medium text-accent-fg hover:bg-accent-hover transition-colors cursor-pointer"
                  >
                    Confirm and Continue
                  </button>
                  <button
                    type="button"
                    phx-click="decline"
                    class="flex-1 justify-center inline-flex items-center rounded-lg border border-chrome-border px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 transition-colors dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-800 cursor-pointer"
                  >
                    This isn't me
                  </button>
                </div>
              <% :consent -> %>
                <h2 class="text-lg font-semibold mb-4">Consent to Electronic Signature</h2>
                <p class="text-sm text-gray-500 mb-6">
                  Please read the following disclosure before proceeding
                </p>

                <div class="mb-6 p-4 bg-gray-50 dark:bg-gray-700/50 rounded-lg text-sm text-gray-600 dark:text-gray-400 space-y-3">
                  <p>
                    By clicking "I Consent" below, you agree to conduct this transaction
                    electronically. You acknowledge that you have read and understand the
                    terms of this document and agree to sign it using an electronic signature.
                  </p>
                  <p>
                    Your electronic signature is legally binding and equivalent to your
                    handwritten signature. You have the right to request a paper copy.
                  </p>
                  <p>
                    You confirm that you are the person identified in this signing request
                    and that you are authorized to sign this document.
                  </p>
                </div>

                <div class="flex gap-3">
                  <button
                    type="button"
                    phx-click="consent_and_review"
                    class="flex-1 justify-center inline-flex items-center rounded-lg bg-accent px-4 py-2 text-sm font-medium text-accent-fg hover:bg-accent-hover transition-colors cursor-pointer"
                  >
                    I Consent &mdash; Review Document
                  </button>
                  <button
                    type="button"
                    phx-click="decline"
                    class="flex-1 justify-center inline-flex items-center rounded-lg border border-chrome-border px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 transition-colors dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-800 cursor-pointer"
                  >
                    I Do Not Consent
                  </button>
                </div>
              <% :review -> %>
                <h2 class="text-lg font-semibold mb-4">Review Document</h2>
                <p class="text-sm text-gray-500 mb-6">
                  Review the document and required fields before signing
                </p>

                <div class="mb-6">
                  <a
                    href={"/sign/#{@token}/document"}
                    target="_blank"
                    class="inline-flex items-center gap-2 px-4 py-2 bg-accent text-white rounded-lg hover:bg-accent/90 transition-colors text-sm font-medium"
                  >
                    Open Document
                  </a>
                </div>

                <%= if @fields != [] do %>
                  <div class="mb-6">
                    <h4 class="text-sm font-medium text-gray-900 dark:text-gray-100 mb-3">
                      Required Fields ({Enum.count(@fields)})
                    </h4>
                    <div class="space-y-2">
                      <%= for field <- @fields do %>
                        <div class="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
                          <span>{field.type || "Signature"} &mdash; Page {field.page_index + 1}</span>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <div class="flex gap-3">
                  <button
                    type="button"
                    phx-click="proceed_to_sign"
                    class="flex-1 justify-center inline-flex items-center rounded-lg bg-accent px-4 py-2 text-sm font-medium text-accent-fg hover:bg-accent-hover transition-colors cursor-pointer"
                  >
                    Proceed to Sign
                  </button>
                  <button
                    type="button"
                    phx-click="decline"
                    class="flex-1 justify-center inline-flex items-center rounded-lg border border-chrome-border px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 transition-colors dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-800 cursor-pointer"
                  >
                    Decline to Sign
                  </button>
                </div>
              <% :sign -> %>
                <h2 class="text-lg font-semibold mb-4">Sign Document</h2>

                <%= if @signing_successful do %>
                  <p class="text-sm text-green-600 mb-4">
                    Your signature has been applied successfully.
                  </p>
                  <button
                    type="button"
                    phx-click="view_receipt"
                    class="w-full justify-center inline-flex items-center rounded-lg bg-accent px-4 py-2 text-sm font-medium text-accent-fg hover:bg-accent-hover transition-colors cursor-pointer"
                  >
                    View Receipt
                  </button>
                <% else %>
                  <p class="text-sm text-gray-500 mb-6">
                    Click below to apply your electronic signature.
                  </p>
                  <div class="mb-6 p-4 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg">
                    <p class="text-sm text-amber-800 dark:text-amber-200">
                      By clicking "Sign", you agree that your electronic signature
                      will be legally equivalent to your handwritten signature.
                    </p>
                  </div>
                  <div class="space-y-3">
                    <button
                      type="button"
                      phx-click="sign_document"
                      class="w-full justify-center inline-flex items-center rounded-lg bg-accent px-4 py-2 text-sm font-medium text-accent-fg hover:bg-accent-hover transition-colors cursor-pointer"
                    >
                      Sign
                    </button>
                    <button
                      type="button"
                      phx-click="back_to_review"
                      class="w-full justify-center inline-flex items-center rounded-lg border border-chrome-border px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 transition-colors dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-800 cursor-pointer"
                    >
                      Back to Review
                    </button>
                    <button
                      type="button"
                      phx-click="decline"
                      class="w-full justify-center inline-flex items-center rounded-lg border border-chrome-border px-4 py-2 text-sm font-medium text-red-600 hover:bg-gray-50 transition-colors dark:border-gray-600 dark:text-red-400 dark:hover:bg-gray-800 cursor-pointer"
                    >
                      Decline to Sign
                    </button>
                  </div>
                <% end %>
              <% :receipt -> %>
                <div class="text-center py-6">
                  <%= if @declined do %>
                    <h2 class="text-xl font-semibold text-gray-900 dark:text-gray-100 mb-2">
                      Request Declined
                    </h2>
                    <p class="text-sm text-gray-600 dark:text-gray-400 mb-6">
                      You have declined to sign "{@envelope.subject}".
                      The sender has been notified.
                    </p>
                  <% else %>
                    <h2 class="text-xl font-semibold text-gray-900 dark:text-gray-100 mb-2">
                      Document Signed!
                    </h2>
                    <p class="text-sm text-gray-600 dark:text-gray-400 mb-6">
                      Thank you, you have successfully signed "{@envelope.subject}".
                    </p>
                  <% end %>
                  <p class="text-xs text-gray-400 dark:text-gray-500">
                    This signing link has been used and can no longer be accessed.
                  </p>
                </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("go_to_consent", _, socket) do
    socket =
      socket
      |> record_signer_viewed()
      |> assign(:step, :consent)
      |> assign(:error, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("consent_and_review", _, socket) do
    {:noreply, assign(socket, :step, :review)}
  end

  @impl true
  def handle_event("proceed_to_sign", _, socket) do
    {:noreply, assign(socket, :step, :sign)}
  end

  @impl true
  def handle_event("back_to_review", _, socket) do
    {:noreply, assign(socket, :step, :review)}
  end

  @impl true
  def handle_event("sign_document", _, socket) do
    %{signer: signer, envelope: envelope} = socket.assigns

    case Esign.sign_envelope(envelope, signer, %{ip_address: socket.assigns[:ip_address]}) do
      {:ok, _updated_signer} ->
        {:noreply,
         socket
         |> assign(:signing_successful, true)
         |> record_audit_event("signed")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Unable to sign: #{format_error(reason)}")}
    end
  end

  @impl true
  def handle_event("view_receipt", _, socket) do
    {:noreply, assign(socket, :step, :receipt)}
  end

  @impl true
  def handle_event("decline", _, socket) do
    %{signer: signer, envelope: envelope} = socket.assigns

    case Esign.decline_envelope(envelope, signer, %{ip_address: socket.assigns[:ip_address]}) do
      {:ok, _updated_signer} ->
        {:noreply,
         socket
         |> assign(:step, :receipt)
         |> assign(:declined, true)
         |> record_audit_event("declined")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Unable to process request: #{format_error(reason)}")}
    end
  end

  defp assign_error(socket, message) do
    assign(socket, :error, message)
    |> assign(:step, nil)
    |> assign(:signer, nil)
    |> assign(:envelope, %{subject: nil})
    |> assign(:token, nil)
  end

  defp record_signer_viewed(socket) do
    %{signer: signer} = socket.assigns

    if signer.status == :pending do
      case Esign.record_signer_view(signer) do
        {:ok, updated} -> assign(socket, :signer, updated)
        {:error, _} -> socket
      end
    else
      socket
    end
  end

  defp record_audit_event(socket, event) do
    %{signer: signer, envelope: envelope} = socket.assigns
    Esign.record_audit_event(envelope, signer, event, %{})
    socket
  end

  defp format_error(:signer_not_viewed_yet), do: "Please view the document first."
  defp format_error(:envelope_not_sent), do: "The envelope has not been sent yet."

  defp format_error(:envelope_already_completed),
    do: "This document has already been signed by all parties."

  defp format_error(:envelope_declined), do: "This document has been declined."
  defp format_error(:envelope_voided), do: "This document has been voided."
  defp format_error(:envelope_expired), do: "This document has expired."
  defp format_error(:already_signed), do: "You have already signed this document."
  defp format_error(:already_declined), do: "You have already declined to sign this document."

  defp format_error(:signer_out_of_order),
    do: "Please wait for the previous signer to sign first."

  defp format_error(reason), do: "An error occurred (#{inspect(reason)}). Please try again."
end
