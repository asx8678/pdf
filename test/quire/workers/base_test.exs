defmodule Quire.Workers.BaseTest do
  use Quire.DataCase

  alias Quire.Workers.Base
  alias Quire.Accounts.License

  import Quire.AccountsFixtures

  describe "license_guard/2" do
    test "allows when user has a license with the required feature" do
      user = user_fixture()

      {:ok, _license} =
        %License{user_id: user.id, tier: "premium"}
        |> License.changeset(%{tier: "premium"})
        |> Quire.Repo.insert()

      assert Base.license_guard(user.id, :ocr) == :ok
    end

    test "denies when user has a license without the feature" do
      user = user_fixture()

      {:ok, _license} =
        %License{user_id: user.id, tier: "standard"}
        |> License.changeset(%{tier: "standard"})
        |> Quire.Repo.insert()

      assert Base.license_guard(user.id, :ocr) == {:error, :license_denied}
    end

    test "denies when user has no license (defaults to trial)" do
      user = user_fixture()

      # Trial allows OCR, so test with a premium-only feature
      assert Base.license_guard(user.id, :translate) == {:error, :license_denied}
    end

    test "allows trial features for user without license" do
      user = user_fixture()

      assert Base.license_guard(user.id, :edit) == :ok
      assert Base.license_guard(user.id, :comment) == :ok
    end

    test "denies for nil user_id" do
      assert Base.license_guard(nil, :edit) == {:error, :license_denied}
    end
  end
end
