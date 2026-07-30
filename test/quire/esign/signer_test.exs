defmodule Quire.Esign.SignerTest do
  use ExUnit.Case, async: true

  alias Quire.Esign.Signer

  describe "valid_transition?/2" do
    test "pending can transition to viewed, declined, pending" do
      assert Signer.valid_transition?(:pending, :viewed)
      assert Signer.valid_transition?(:pending, :declined)
      assert Signer.valid_transition?(:pending, :pending)
    end

    test "pending cannot jump to signed" do
      refute Signer.valid_transition?(:pending, :signed)
    end

    test "viewed can transition to signed or declined" do
      assert Signer.valid_transition?(:viewed, :signed)
      assert Signer.valid_transition?(:viewed, :declined)
    end

    test "viewed cannot go back to pending" do
      refute Signer.valid_transition?(:viewed, :pending)
    end

    test "signed and declined are terminal" do
      for state <- [:signed, :declined] do
        refute Signer.valid_transition?(state, :viewed)
        refute Signer.valid_transition?(state, :pending)
        refute Signer.valid_transition?(state, :signed)
        refute Signer.valid_transition?(state, :declined)
      end
    end
  end
end
