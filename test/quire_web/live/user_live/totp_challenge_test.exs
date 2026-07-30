defmodule QuireWeb.UserLive.TotpChallengeTest do
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures

  alias Quire.Accounts

  describe "TOTP challenge page" do
    test "renders the challenge form with valid session", %{conn: conn} do
      user = user_fixture()
      {:ok, secret, user} = Accounts.generate_totp_secret(user)
      code = NimbleTOTP.verification_code(secret)
      {:ok, user} = Accounts.enable_totp(user, code)

      conn =
        conn
        |> init_test_session(totp_user_id: user.id)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in/totp")
      assert html =~ "Two-Factor Authentication"
      assert html =~ "Enter the 6-digit code"
    end

    test "redirects to login page without session", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/users/log-in/totp")
    end

    test "redirects to login for non-totp user", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(totp_user_id: user.id)

      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/users/log-in/totp")
    end

    test "valid code redirects to complete endpoint and logs user in", %{conn: conn} do
      user = user_fixture()
      {:ok, secret, user} = Accounts.generate_totp_secret(user)
      code = NimbleTOTP.verification_code(secret)
      {:ok, user} = Accounts.enable_totp(user, code)

      conn =
        conn
        |> init_test_session(totp_user_id: user.id)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/totp")

      result =
        lv
        |> form("#totp-challenge-form", user: %{code: code})
        |> render_submit()

      {:ok, conn} = follow_redirect(result, conn, ~p"/users/log-in/totp/complete")
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ user.email
    end

    test "invalid code shows error", %{conn: conn} do
      user = user_fixture()
      {:ok, secret, user} = Accounts.generate_totp_secret(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, user} = Accounts.enable_totp(user, valid_code)

      conn =
        conn
        |> init_test_session(totp_user_id: user.id)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/totp")

      result =
        lv
        |> form("#totp-challenge-form", user: %{code: "000000"})
        |> render_submit()

      assert result =~ "Invalid code. Please try again."
    end
  end
end
