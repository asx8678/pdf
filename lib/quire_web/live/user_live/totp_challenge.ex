defmodule QuireWeb.UserLive.TotpChallenge do
  use QuireWeb, :live_view

  alias Quire.Accounts

  @impl true
  def mount(_params, session, socket) do
    user_id = session["totp_user_id"]

    if user_id do
      user = Accounts.get_user!(user_id)

      if user.totp_enabled do
        form = to_form(%{"code" => ""}, as: :user)

        {:ok,
         socket
         |> assign(:totp_form, form)
         |> assign(:totp_error, nil)
         |> assign(:user, user)}
      else
        {:ok,
         socket
         |> put_flash(:error, "TOTP is not enabled for this account.")
         |> push_navigate(to: ~p"/users/log-in")}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Please log in first.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm my-16">
        <div class="text-center mb-8">
          <.header>
            Two-Factor Authentication
            <:subtitle>
              Enter the 6-digit code from your authenticator app to complete login.
            </:subtitle>
          </.header>
        </div>

        <.form
          for={@totp_form}
          id="totp-challenge-form"
          phx-submit="verify_code"
          class="space-y-4"
        >
          <.input
            field={@totp_form[:code]}
            type="text"
            label="Authentication code"
            placeholder="000000"
            maxlength="6"
            autocomplete="off"
            required
            class="text-center text-lg tracking-widest"
          />
          <.button variant="primary" class="w-full" phx-disable-with="Verifying...">
            Verify
          </.button>
        </.form>

        <p :if={@totp_error} class="mt-3 text-sm text-red-600 dark:text-red-400 text-center">
          {@totp_error}
        </p>

        <div class="mt-6 text-center">
          <.link
            href={~p"/users/log-in"}
            class="text-sm text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200 underline"
          >
            Back to login
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("verify_code", %{"user" => %{"code" => code}}, socket) do
    user = socket.assigns.user

    if Accounts.verify_totp_code(user, code) do
      {:noreply,
       socket
       |> redirect(to: ~p"/users/log-in/totp/complete")}
    else
      {:noreply, assign(socket, :totp_error, "Invalid code. Please try again.")}
    end
  end
end
