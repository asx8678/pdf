defmodule QuireWeb.UserSessionController do
  use QuireWeb, :controller

  alias Quire.Accounts
  alias QuireWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      if user.totp_enabled do
        # Don't log in yet — redirect to TOTP challenge
        conn
        |> put_session(:totp_user_id, user.id)
        |> redirect(to: ~p"/users/log-in/totp")
      else
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)
      end
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  @doc """
  Called after TOTP challenge succeeds. Copies the tentative user ID from
  the session into a real login session.
  """
  def totp_complete(conn, _params) do
    user_id = get_session(conn, :totp_user_id)
    user = user_id && Accounts.get_user!(user_id)

    if user && user.totp_enabled do
      conn
      |> delete_session(:totp_user_id)
      |> put_flash(:info, "Welcome back!")
      |> UserAuth.log_in_user(user, %{})
    else
      conn
      |> put_flash(:error, "Invalid session.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
