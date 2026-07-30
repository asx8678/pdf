defmodule QuireWeb.UserLive.ResetPassword do
  use QuireWeb, :live_view

  alias Quire.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>Reset password</p>
            <:subtitle>
              Choose a new password for your account.
            </:subtitle>
          </.header>
        </div>

        <div
          :if={@token_invalid}
          class="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700 dark:border-red-800 dark:bg-red-900/20 dark:text-red-400"
        >
          <p>
            This reset link is invalid or has expired.
            <.link
              navigate={~p"/users/forgot-password"}
              class="font-semibold underline"
              phx-no-format
            >
              Request a new one
            </.link>.
          </p>
        </div>

        <.form :if={!@token_invalid} for={@form} id="reset-password-form" phx-submit="reset_password">
          <.input
            field={@form[:password]}
            type="password"
            label="New password"
            autocomplete="new-password"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirm new password"
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.button class="w-full">
            Reset password
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_user_by_reset_password_token(token) do
      nil ->
        {:ok, assign(socket, token: token, token_invalid: true, form: nil)}

      user ->
        form = to_form(%{"password" => "", "password_confirmation" => ""}, as: "user")
        {:ok, assign(socket, token: token, token_invalid: false, user: user, form: form)}
    end
  end

  @impl true
  def handle_event("reset_password", %{"user" => attrs}, socket) do
    user = socket.assigns.user

    case Accounts.reset_user_password(user, %{password: attrs["password"], password_confirmation: attrs["password_confirmation"]}) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password reset successfully.")
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
    end
  end
end
