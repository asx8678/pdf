defmodule QuireWeb.UserLive.ForgotPassword do
  use QuireWeb, :live_view

  alias Quire.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>Forgot your password?</p>
            <:subtitle>
              Enter your email address and we'll send you a reset link.
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="forgot-password-form" phx-submit="send_reset">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="w-full" disabled={@submitted}>
            {@submitted && "Email sent" || "Send reset instructions"}
          </.button>
        </.form>

        <p class="text-center text-sm text-gray-500">
          Remember your password?
          <.link navigate={~p"/users/log-in"} class="font-semibold text-accent hover:underline">
            Log in
          </.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    form = to_form(%{"email" => ""}, as: "user")
    {:ok, assign(socket, form: form, submitted: false)}
  end

  @impl true
  def handle_event("send_reset", %{"user" => %{"email" => email}}, socket) do
    Accounts.deliver_user_reset_password_instructions(email, &url(~p"/users/reset-password/#{&1}"))

    {:noreply,
     socket
     |> put_flash(:info, "If your email is in our system, you will receive reset instructions shortly.")
     |> assign(:submitted, true)}
  end
end
