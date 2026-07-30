defmodule Quire.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Quire.Repo

  alias Quire.Accounts.{User, UserSetting, UserToken, UserNotifier, SigningCredential}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    # Matches the lower(email) unique index rather than the raw column, so
    # lookups stay case-insensitive without citext (§3.4 bans extensions).
    Repo.one(from u in User, where: fragment("lower(?)", u.email) == ^String.downcase(email))
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Quire.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Quire.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Signing credentials

  @doc """
  Lists all signing credentials for the given user.
  """
  def list_signing_credentials(user_id) do
    Repo.all(from sc in SigningCredential, where: sc.user_id == ^user_id, order_by: sc.label)
  end

  @doc """
  Gets a single signing credential.

  Raises `Ecto.NoResultsError` if none exists.
  """
  def get_signing_credential!(id), do: Repo.get!(SigningCredential, id)

  @doc """
  Creates a signing credential for the given user.

  **Must be called from within sudo mode (§11.1).**
  `user_id` is set programmatically from the `user` struct and is never
  taken from `attrs`.
  """
  def create_signing_credential(%{id: user_id} = _user, attrs) do
    %SigningCredential{user_id: user_id}
    |> SigningCredential.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a signing credential. **Must be called from within sudo mode.**
  """
  def update_signing_credential(%SigningCredential{} = credential, attrs) do
    credential
    |> SigningCredential.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a signing credential. **Must be called from within sudo mode.**
  """
  def delete_signing_credential(%SigningCredential{} = credential) do
    Repo.delete(credential)
  end

  @doc """
  Changeset for the signing-credential form.
  """
  def change_signing_credential(credential, attrs \\ %{}) do
    SigningCredential.changeset(credential, attrs)
  end

  ## User settings

  @doc """
  Gets user settings for the given `user_id`.

  Returns a `%UserSetting{}` with defaults if no row exists yet.
  """
  def get_user_settings(user_id) do
    case Repo.get_by(UserSetting, user_id: user_id) do
      nil -> %UserSetting{user_id: user_id}
      setting -> setting
    end
  end

  @doc """
  Creates or updates user settings for the given `user_id`.

  `user_id` is set programmatically — it is never taken from `attrs`.
  """
  def update_user_settings(user_id, attrs) do
    setting = Repo.get_by(UserSetting, user_id: user_id) || %UserSetting{user_id: user_id}
    UserSetting.upsert(setting, attrs, user_id)
  end

  @doc """
  Updates only the QAT items (toolbar customisation) for the given `user_id`.
  """
  def update_qat_items(user_id, items) do
    update_user_settings(user_id, %{qat_items: items})
  end

  ## Saved signatures

  @doc """
  Returns saved signatures for the given `user_id`.

  Signatures are stored as a list of maps under the `signatures` key in
  user_settings. Each entry has:
    `id` — UUID for identification
    `label` — user-given name
    `type` — "draw" | "type" | "upload"
    `data` — mode-specific payload (curve data, text+font, or image bytes)
    `created_at` — ISO8601 timestamp
  """
  def list_saved_signatures(user_id) do
    settings = get_user_settings(user_id)
    Map.get(settings, :signatures) || []
  end

  @doc """
  Saves a new signature for the given `user_id`.

  Returns `{:ok, updated_signatures}` or `{:error, reason}`.
  """
  def save_signature(user_id, attrs) do
    current = list_saved_signatures(user_id)

    signature = %{
      "id" => Ecto.UUID.generate(),
      "label" => attrs["label"] || attrs[:label] || "Signature",
      "type" => attrs["type"] || attrs[:type],
      "data" => attrs["data"] || attrs[:data],
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case update_user_settings(user_id, %{signatures: [signature | current]}) do
      {:ok, _setting} -> {:ok, signature}
      error -> error
    end
  end

  @doc """
  Deletes a saved signature by `id` for the given `user_id`.
  """
  def delete_saved_signature(user_id, sig_id) do
    current = list_saved_signatures(user_id)
    updated = Enum.reject(current, &(&1["id"] == sig_id))
    update_user_settings(user_id, %{signatures: updated})
  end

  @doc """
  Updates a saved signature's label for the given `user_id`.
  """
  def update_signature_label(user_id, sig_id, new_label) do
    current = list_saved_signatures(user_id)

    updated =
      Enum.map(current, fn
        %{"id" => ^sig_id} = sig -> Map.put(sig, "label", new_label)
        sig -> sig
      end)

    update_user_settings(user_id, %{signatures: updated})
  end

  ## Saved stamps

  @doc """
  Returns saved custom stamps for the given `user_id`.

  Stamps are stored as a list of maps under the `stamps` key in
  user_settings. Each entry has:
    `id` — UUID for identification
    `label` — user-given name
    `type` — "image" | "text"
    `data` — mode-specific payload (SVG/image data, or text+font)
    `created_at` — ISO8601 timestamp
  """
  def list_saved_stamps(user_id) do
    settings = get_user_settings(user_id)
    Map.get(settings, :stamps) || []
  end

  @doc """
  Saves a custom stamp for the given `user_id`.

  Returns `{:ok, stamp}` or `{:error, reason}`.
  """
  def save_stamp(user_id, attrs) do
    current = list_saved_stamps(user_id)

    stamp = %{
      "id" => Ecto.UUID.generate(),
      "label" => attrs["label"] || attrs[:label] || "Custom stamp",
      "type" => attrs["type"] || attrs[:type],
      "data" => attrs["data"] || attrs[:data],
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case update_user_settings(user_id, %{stamps: [stamp | current]}) do
      {:ok, _setting} -> {:ok, stamp}
      error -> error
    end
  end

  @doc """
  Deletes a saved stamp by `id` for the given `user_id`.
  """
  def delete_saved_stamp(user_id, stamp_id) do
    current = list_saved_stamps(user_id)
    updated = Enum.reject(current, &(&1["id"] == stamp_id))
    update_user_settings(user_id, %{stamps: updated})
  end

  @doc """
  Updates a saved stamp's label for the given `user_id`.
  """
  def update_stamp_label(user_id, stamp_id, new_label) do
    current = list_saved_stamps(user_id)

    updated =
      Enum.map(current, fn
        %{"id" => ^stamp_id} = stamp -> Map.put(stamp, "label", new_label)
        stamp -> stamp
      end)

    update_user_settings(user_id, %{stamps: updated})
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  @doc """
  Delivers reset password email instructions.

  If the email exists, a reset token is generated and emailed.
  Returns `:ok` regardless of whether the email exists (to avoid leaking
  user existence).
  """
  def deliver_user_reset_password_instructions(email, url_fun) when is_binary(email) do
    if user = get_user_by_email(email) do
      {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
      Repo.insert!(user_token)
      UserNotifier.deliver_reset_password_instructions(user, url_fun.(encoded_token))
    end

    :ok
  end

  @doc """
  Gets a user by a valid reset password token.

  If the token is invalid or expired, returns `nil`.
  """
  def get_user_by_reset_password_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_reset_password_token_query(token),
         [{user, _token}] <- Repo.all(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user's password using a valid reset token.

  The token is consumed (deleted) after a successful reset.
  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def reset_user_password(user, attrs) do
    changeset = User.password_changeset(user, attrs)
    update_user_and_delete_all_tokens(changeset)
  end
end
