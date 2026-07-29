defmodule Quire.Accounts.SigningCredentialTest do
  use Quire.DataCase, async: true

  alias Quire.Accounts
  alias Quire.Accounts.SigningCredential
  alias Quire.Repo

  import Quire.AccountsFixtures

  describe "create_signing_credential/2" do
    test "creates a credential with encrypted passphrase" do
      user = user_fixture()

      assert {:ok, %SigningCredential{} = credential} =
               Accounts.create_signing_credential(user, %{
                 label: "My Cert",
                 keystore_ref_key: "store/abc123.p12",
                 passphrase_encrypted: "s3cret"
               })

      assert credential.user_id == user.id
      assert credential.label == "My Cert"
      assert credential.keystore_ref_key == "store/abc123.p12"
    end

    test "stores passphrase as ciphertext in the database, decrypts on read" do
      user = user_fixture()

      {:ok, credential} =
        Accounts.create_signing_credential(user, %{
          label: "My Cert",
          keystore_ref_key: "store/abc123.p12",
          passphrase_encrypted: "hunter2"
        })

      # Raw DB row has ciphertext, not the original string
      raw =
        Ecto.Adapters.SQL.query!(
          Quire.Repo,
          "SELECT passphrase_encrypted FROM signing_credentials WHERE id = $1::uuid",
          [Ecto.UUID.dump!(credential.id)]
        )
        |> Map.fetch!(:rows)
        |> hd()
        |> hd()

      assert is_binary(raw), "expected binary ciphertext"
      refute raw == "hunter2", "passphrase must be encrypted at rest"
      assert byte_size(raw) > 16

      # Reload from DB triggers Cloak load/1 which decrypts back to plaintext
      reloaded = Repo.get!(SigningCredential, credential.id)
      assert reloaded.passphrase_encrypted == "hunter2"
    end

    test "fails without required fields" do
      user = user_fixture()

      assert {:error, changeset} = Accounts.create_signing_credential(user, %{})
      assert "can't be blank" in errors_on(changeset).label
      assert "can't be blank" in errors_on(changeset).keystore_ref_key
      assert "can't be blank" in errors_on(changeset).passphrase_encrypted
    end

    test "enforces unique label per user" do
      user = user_fixture()

      assert {:ok, _} =
               Accounts.create_signing_credential(user, %{
                 label: "Same Label",
                 keystore_ref_key: "store/abc.p12",
                 passphrase_encrypted: "pass1"
               })

      assert {:error, changeset} =
               Accounts.create_signing_credential(user, %{
                 label: "Same Label",
                 keystore_ref_key: "store/def.p12",
                 passphrase_encrypted: "pass2"
               })

      assert {"has already been taken", _} = changeset.errors[:label]
    end
  end

  describe "update_signing_credential/2" do
    test "updates credential attributes" do
      user = user_fixture()

      {:ok, credential} =
        Accounts.create_signing_credential(user, %{
          label: "Old Label",
          keystore_ref_key: "store/abc.p12",
          passphrase_encrypted: "old_pass"
        })

      assert {:ok, %SigningCredential{label: "New Label"}} =
               Accounts.update_signing_credential(credential, %{label: "New Label"})
    end
  end

  describe "delete_signing_credential/1" do
    test "deletes the credential" do
      user = user_fixture()

      {:ok, credential} =
        Accounts.create_signing_credential(user, %{
          label: "Delete Me",
          keystore_ref_key: "store/abc.p12",
          passphrase_encrypted: "del_pass"
        })

      assert {:ok, %SigningCredential{}} = Accounts.delete_signing_credential(credential)

      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_signing_credential!(credential.id)
      end
    end
  end

  describe "list_signing_credentials/1" do
    test "lists credentials for a user" do
      user = user_fixture()

      {:ok, _} =
        Accounts.create_signing_credential(user, %{
          label: "A",
          keystore_ref_key: "store/a.p12",
          passphrase_encrypted: "a"
        })

      {:ok, _} =
        Accounts.create_signing_credential(user, %{
          label: "B",
          keystore_ref_key: "store/b.p12",
          passphrase_encrypted: "b"
        })

      credentials = Accounts.list_signing_credentials(user.id)
      assert length(credentials) == 2
    end
  end
end
