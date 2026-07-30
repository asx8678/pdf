defmodule Quire.Accounts.ActivationTest do
  use Quire.DataCase

  import Quire.AccountsFixtures

  alias Quire.Accounts
  alias Quire.Accounts.License

  defp create_license_key(attrs) do
    owner = user_fixture()

    %License{}
    |> License.changeset(attrs)
    |> put_change(:user_id, owner.id)
    |> Quire.Repo.insert!()

    owner
  end

  describe "validate_activation_key/2" do
    test "rejects empty key" do
      user = user_fixture()

      assert Accounts.validate_activation_key(user, "") ==
               {:error, "Please enter an activation key."}

      assert Accounts.validate_activation_key(user, nil) ==
               {:error, "Please enter an activation key."}
    end

    test "rejects unknown key" do
      user = user_fixture()

      assert Accounts.validate_activation_key(user, "INVALID-KEY") ==
               {:error, "Invalid activation key. Please check the key and try again."}
    end

    test "rejects expired key" do
      create_license_key(%{
        tier: "premium",
        activation_key: "EXPIRED-KEY",
        expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
      })

      user = user_fixture()

      assert Accounts.validate_activation_key(user, "EXPIRED-KEY") ==
               {:error, "This activation key has expired."}
    end

    test "activates the user's license with a valid key" do
      create_license_key(%{
        tier: "premium",
        seats: 5,
        activation_key: "VALID-KEY-12345"
      })

      user = user_fixture()
      assert {:ok, license} = Accounts.validate_activation_key(user, "VALID-KEY-12345")
      assert license.tier == "premium"
      assert license.activation_key == "VALID-KEY-12345"
    end

    test "upserts when user already has a license (trial upgrade)" do
      user = user_fixture()

      # Pre-insert a trial license for this user
      %License{}
      |> License.changeset(%{
        tier: "trial",
        activated_at: DateTime.utc_now()
      })
      |> put_change(:user_id, user.id)
      |> Quire.Repo.insert!(on_conflict: :nothing, conflict_target: :user_id)

      # The activation key owned by a different user
      create_license_key(%{
        tier: "business",
        activation_key: "UPGRADE-KEY"
      })

      assert {:ok, license} = Accounts.validate_activation_key(user, "UPGRADE-KEY")
      assert license.tier == "business"

      # Verify DB was upserted to business
      updated = Quire.Repo.get_by!(License, user_id: user.id)
      assert updated.tier == "business"
      assert updated.activation_key == "UPGRADE-KEY"
    end
  end
end
