defmodule Quire.LicensingTest do
  use Quire.DataCase

  alias Quire.Licensing
  alias Quire.Accounts.License

  import Quire.AccountsFixtures

  describe "allows?/2 - raw tier" do
    test "trial tier allows trial features" do
      assert Licensing.allows?("trial", :edit)
      assert Licensing.allows?("trial", :comment)
      assert Licensing.allows?("trial", :fill_sign)
      assert Licensing.allows?("trial", :secure)
      assert Licensing.allows?("trial", :ocr)
      assert Licensing.allows?("trial", :export)
    end

    test "trial tier denies premium features" do
      refute Licensing.allows?("trial", :esign)
      refute Licensing.allows?("trial", :translate)
      refute Licensing.allows?("trial", :desktop)
      refute Licensing.allows?("trial", :cloud_sync)
      refute Licensing.allows?("trial", :sso)
      refute Licensing.allows?("trial", :audit)
    end

    test "standard tier denies ocr, esign and translate" do
      refute Licensing.allows?("standard", :ocr)
      refute Licensing.allows?("standard", :esign)
      refute Licensing.allows?("standard", :translate)
    end

    test "premium tier allows ocr, esign and translate" do
      assert Licensing.allows?("premium", :ocr)
      assert Licensing.allows?("premium", :esign)
      assert Licensing.allows?("premium", :translate)
    end

    test "premium tier denies desktop and cloud" do
      refute Licensing.allows?("premium", :desktop)
      refute Licensing.allows?("premium", :cloud_sync)
    end

    test "business tier allows all features" do
      all_features = [
        :edit, :comment, :fill_sign, :secure, :esign,
        :ocr, :translate, :desktop, :cloud_sync, :sso, :audit, :export
      ]

      for feature <- all_features do
        assert Licensing.allows?("business", feature),
               "expected business tier to allow #{feature}"
      end
    end

    test "nil user is treated as trial" do
      assert Licensing.allows?(nil, :ocr)
      refute Licensing.allows?(nil, :translate)
    end

    test "unknown tier defaults to standard" do
      refute Licensing.allows?("enterprise", :ocr)
    end
  end

  describe "allows?/2 - user with license" do
    test "user with trial license allows trial features" do
      user = user_fixture()

      {:ok, _license} =
        %License{user_id: user.id, tier: "trial"}
        |> License.changeset(%{tier: "trial"})
        |> Quire.Repo.insert()

      user_with_license = Quire.Repo.preload(user, :license)
      assert Licensing.allows?(user_with_license, :ocr)
      refute Licensing.allows?(user_with_license, :translate)
    end

    test "user with premium license allows premium features" do
      user = user_fixture()

      {:ok, _license} =
        %License{user_id: user.id, tier: "premium"}
        |> License.changeset(%{tier: "premium"})
        |> Quire.Repo.insert()

      user_with_license = Quire.Repo.preload(user, :license)
      assert Licensing.allows?(user_with_license, :ocr)
      assert Licensing.allows?(user_with_license, :esign)
    end

    test "user without license defaults to trial" do
      user = user_fixture()
      assert Licensing.allows?(user, :ocr)
      refute Licensing.allows?(user, :translate)
    end
  end

  describe "refusal_message/1" do
    test "returns plain language message" do
      msg = Licensing.refusal_message(:ocr)
      assert is_binary(msg)
      assert msg =~ "higher licensing tier"
    end
  end

  describe "tiers/0" do
    test "returns tiers in order" do
      assert Licensing.tiers() == ["trial", "standard", "premium", "business"]
    end
  end

  describe "expiring_soon?/1" do
    test "returns true when license expires within 7 days" do
      user = user_fixture()

      {:ok, _license} =
        %License{user_id: user.id, tier: "trial"}
        |> License.changeset(%{tier: "trial", expires_at: DateTime.add(DateTime.utc_now(), 3, :day)})
        |> Quire.Repo.insert()

      assert Licensing.expiring_soon?(user)
    end

    test "returns false when license expires beyond 7 days" do
      user = user_fixture()

      {:ok, _license} =
        %License{user_id: user.id, tier: "trial"}
        |> License.changeset(%{tier: "trial", expires_at: DateTime.add(DateTime.utc_now(), 30, :day)})
        |> Quire.Repo.insert()

      refute Licensing.expiring_soon?(user)
    end

    test "returns false when license has no expiry" do
      user = user_fixture()

      {:ok, _license} =
        %License{user_id: user.id, tier: "standard"}
        |> License.changeset(%{tier: "standard"})
        |> Quire.Repo.insert()

      refute Licensing.expiring_soon?(user)
    end

    test "returns false when user has no license" do
      user = user_fixture()
      refute Licensing.expiring_soon?(user)
    end

    test "returns false for nil" do
      refute Licensing.expiring_soon?(nil)
    end

    test "accepts scope-like map with :user key" do
      user = user_fixture()

      {:ok, _license} =
        %License{user_id: user.id, tier: "trial"}
        |> License.changeset(%{tier: "trial", expires_at: DateTime.add(DateTime.utc_now(), 3, :day)})
        |> Quire.Repo.insert()

      assert Licensing.expiring_soon?(%{user: user})
    end
  end
end
