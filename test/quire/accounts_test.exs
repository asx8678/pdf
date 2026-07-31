defmodule Quire.AccountsTest do
  use Quire.DataCase

  alias Quire.Accounts

  import Quire.AccountsFixtures
  alias Quire.Accounts.{User, UserToken}

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!("11111111-1111-1111-1111-111111111111")
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_user(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers users without password" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_nil(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, [%{token: ^hashed_token}]}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {^user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed user has password set" do
      user = unconfirmed_user_fixture()
      {1, nil} = Repo.update_all(User, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_user_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "login"
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "deliver_user_reset_password_instructions/2" do
    test "returns :ok for existing user" do
      user = user_fixture()

      assert :ok =
               Accounts.deliver_user_reset_password_instructions(user.email, fn token ->
                 "https://example.com/reset/#{token}"
               end)
    end

    test "returns :ok for non-existent email (no leaking)" do
      assert :ok =
               Accounts.deliver_user_reset_password_instructions(
                 "nonexistent@example.com",
                 fn _token -> "https://example.com/reset/token" end
               )
    end
  end

  describe "get_user_by_reset_password_token/1" do
    test "returns user for valid token" do
      user = user_fixture()

      # Generate a reset token directly
      {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
      Quire.Repo.insert!(user_token)

      found = Accounts.get_user_by_reset_password_token(encoded_token)
      assert found
      assert found.id == user.id
    end

    test "returns nil for invalid token" do
      assert Accounts.get_user_by_reset_password_token("invalid-token") == nil
    end

    test "returns nil for expired token" do
      user = user_fixture()

      {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
      %{id: id} = Quire.Repo.insert!(user_token)

      # Offset the token's inserted_at to be expired (past 60 min validity)
      Quire.Repo.update_all(
        from(t in UserToken, where: t.id == ^id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -3600 * 2, :second)]
      )

      assert Accounts.get_user_by_reset_password_token(encoded_token) == nil
    end
  end

  describe "reset_user_password/2" do
    test "updates the password" do
      user = user_fixture()
      user = set_password(user)
      assert User.valid_password?(user, valid_user_password())

      {:ok, {user, _}} =
        Accounts.reset_user_password(user, %{
          password: "new-valid-password-123",
          password_confirmation: "new-valid-password-123"
        })

      refute User.valid_password?(user, valid_user_password())
      assert User.valid_password?(user, "new-valid-password-123")
    end

    test "returns error for mismatched confirmation" do
      user = user_fixture()
      user = set_password(user)

      assert {:error, changeset} =
               Accounts.reset_user_password(user, %{
                 password: "new-valid-password-123",
                 password_confirmation: "different-password"
               })

      assert changeset.errors[:password_confirmation]
    end
  end

  describe "TOTP 2FA" do
    test "generate_totp_secret/1 returns secret and updates user" do
      user = user_fixture()
      assert user.totp_secret == nil
      refute user.totp_enabled

      assert {:ok, secret, updated_user} = Accounts.generate_totp_secret(user)
      assert is_binary(secret)
      assert byte_size(secret) == 20
      assert updated_user.totp_secret != nil
      refute updated_user.totp_enabled
    end

    test "enable_totp/2 returns error for invalid code" do
      user = user_fixture()
      {:ok, _secret, user} = Accounts.generate_totp_secret(user)

      assert Accounts.enable_totp(user, "000000") == {:error, :invalid_code}
      refute refresh(user).totp_enabled
    end

    test "enable_totp/2 succeeds with valid code" do
      user = user_fixture()
      {:ok, secret, user} = Accounts.generate_totp_secret(user)

      valid_code = NimbleTOTP.verification_code(secret)
      assert {:ok, enabled_user} = Accounts.enable_totp(user, valid_code)
      assert enabled_user.totp_enabled
      assert refresh(user).totp_enabled
    end

    test "verify_totp_code/2 returns false when totp not enabled" do
      user = user_fixture()
      {:ok, secret, user} = Accounts.generate_totp_secret(user)

      code = NimbleTOTP.verification_code(secret)
      refute Accounts.verify_totp_code(user, code)
    end

    test "verify_totp_code/2 returns true with valid code when enabled" do
      user = user_fixture()
      {:ok, secret, user} = Accounts.generate_totp_secret(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, user} = Accounts.enable_totp(user, valid_code)

      assert Accounts.verify_totp_code(user, valid_code)
    end

    test "verify_totp_code/2 returns false for invalid code" do
      user = user_fixture()
      {:ok, secret, user} = Accounts.generate_totp_secret(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, user} = Accounts.enable_totp(user, valid_code)

      refute Accounts.verify_totp_code(user, "000000")
    end

    test "disable_totp/1 clears secret and disables" do
      user = user_fixture()
      {:ok, secret, user} = Accounts.generate_totp_secret(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, user} = Accounts.enable_totp(user, valid_code)

      assert {:ok, updated_user} = Accounts.disable_totp(user)
      refute updated_user.totp_enabled
      assert updated_user.totp_secret == nil
      assert refresh(user).totp_enabled == false
    end

    defp refresh(user), do: Quire.Repo.reload!(user)
  end

  describe "saved initials" do
    test "save_initials/2 stores in the initials slot only" do
      user = user_fixture()

      assert {:ok, saved} =
               Accounts.save_initials(user.id, %{
                 "label" => "AB",
                 "type" => "type",
                 "data" => Jason.encode!(%{text: "AB", font: "Alex Brush", size: 48})
               })

      assert saved["label"] == "AB"
      assert Accounts.list_saved_initials(user.id) == [saved]
      # Independent of the signatures slot
      assert Accounts.list_saved_signatures(user.id) == []
    end

    test "delete_saved_initials/2 removes only the target entry" do
      user = user_fixture()
      {:ok, a} = Accounts.save_initials(user.id, %{"label" => "A", "type" => "type", "data" => "{}"})
      {:ok, b} = Accounts.save_initials(user.id, %{"label" => "B", "type" => "type", "data" => "{}"})

      assert {:ok, _} = Accounts.delete_saved_initials(user.id, a["id"])
      assert Accounts.list_saved_initials(user.id) == [b]
    end

    test "update_initials_label/3 renames the entry" do
      user = user_fixture()
      {:ok, saved} = Accounts.save_initials(user.id, %{"label" => "Old", "type" => "type", "data" => "{}"})

      assert {:ok, _} = Accounts.update_initials_label(user.id, saved["id"], "New")
      [updated] = Accounts.list_saved_initials(user.id)
      assert updated["label"] == "New"
    end
  end
end
