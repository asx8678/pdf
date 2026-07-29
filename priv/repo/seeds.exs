# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Quire.Repo.insert!(%Quire.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Dev account so Phases 0-11 have a session to work against. Everything
# downstream assumes one exists: the EditSession Registry is keyed on
# {document_id, user_id} (§7.4), documents.owner_id has to point somewhere, and
# T-041's auth check needs something real to authenticate.
#
# Credentials are deliberately committed — the app is localhost-only until
# Phase 10, and a dev seed nobody can log into is worse than useless. This must
# not survive into any deployed environment.

alias Quire.Accounts

email = "dev@quire.test"
password = "dev-password-1234"

case Accounts.get_user_by_email(email) do
  nil ->
    # Three ordered steps, all required. register_user/1 casts only :email, so
    # the account starts with no password. Setting a password before confirming
    # makes login_user_by_magic_link/1 raise, so confirm first.
    {:ok, user} = Accounts.register_user(%{email: email})

    {:ok, user} =
      user
      |> Quire.Accounts.User.confirm_changeset()
      |> Quire.Repo.update()

    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: password})

    IO.puts("seeded dev user #{user.email} (#{user.id})")

  user ->
    IO.puts("dev user #{user.email} already seeded (#{user.id})")
end
