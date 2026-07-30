defmodule Quire.EsignTest do
  use ExUnit.Case, async: true

  alias Quire.Esign
  alias Quire.Esign.{Envelope, Signer}

  describe "valid_transition?/2 guards" do
    test "envelope transitions match the state machine" do
      assert Envelope.valid_transition?(:draft, :sent)
      assert Envelope.valid_transition?(:sent, :partially_signed)
      assert Envelope.valid_transition?(:sent, :declined)
      assert Envelope.valid_transition?(:sent, :voided)
      assert Envelope.valid_transition?(:sent, :expired)
      assert Envelope.valid_transition?(:partially_signed, :completed)
      assert Envelope.valid_transition?(:partially_signed, :declined)
      assert Envelope.valid_transition?(:partially_signed, :voided)
      assert Envelope.valid_transition?(:partially_signed, :expired)

      # Terminal states
      for state <- [:completed, :declined, :voided, :expired],
          target <- [:draft, :sent, :partially_signed, :completed, :declined, :voided, :expired] do
        refute Envelope.valid_transition?(state, target),
               "#{state} -> #{target} should be rejected"
      end
    end

    test "signer transitions match the state machine" do
      assert Signer.valid_transition?(:pending, :viewed)
      assert Signer.valid_transition?(:pending, :declined)
      assert Signer.valid_transition?(:viewed, :signed)
      assert Signer.valid_transition?(:viewed, :declined)

      refute Signer.valid_transition?(:pending, :signed)

      for state <- [:signed, :declined] do
        refute Signer.valid_transition?(state, :pending)
        refute Signer.valid_transition?(state, :viewed)
        refute Signer.valid_transition?(state, :signed)
      end
    end
  end

  describe "send_envelope guards" do
    test "returns :invalid_transition for non-draft envelopes" do
      env = %Envelope{status: :sent}
      assert {:error, :invalid_transition} = Esign.send_envelope(env)
    end

    test "returns :invalid_transition for terminal states" do
      for status <- [:completed, :declined, :voided, :expired] do
        assert {:error, :invalid_transition} = Esign.send_envelope(%Envelope{status: status})
      end
    end

    test "draft envelope attempts send via changeset" do
      assert {:error, _changeset} = Esign.send_envelope(%Envelope{status: :draft})
    end
  end

  describe "void_envelope guards" do
    test "only sent/partially_signed envelopes can be voided" do
      assert {:error, _changeset} = Esign.void_envelope(%Envelope{status: :draft})
      assert {:error, :invalid_transition} = Esign.void_envelope(%Envelope{status: :completed})
      assert {:error, :invalid_transition} = Esign.void_envelope(%Envelope{status: :declined})
    end
  end

  describe "expire_envelope guards" do
    test "only sent/partially_signed can be expired" do
      assert {:error, :invalid_transition} = Esign.expire_envelope(%Envelope{status: :draft})
      assert {:error, :invalid_transition} = Esign.expire_envelope(%Envelope{status: :completed})
    end
  end

  describe "decline_envelope guards" do
    test "decline requires sent envelope and pending signer" do
      env = %Envelope{status: :sent}
      signer = %Signer{status: :pending}
      assert {:error, _changeset} = Esign.decline_envelope(env, signer)

      # Wrong envelope state
      assert {:error, :invalid_transition} =
               Esign.decline_envelope(%Envelope{status: :draft}, signer)

      # Wrong signer state
      assert {:error, :invalid_transition} =
               Esign.decline_envelope(env, %Signer{status: :viewed})
    end
  end

  describe "add_signer guards" do
    test "only draft envelopes accept new signers" do
      assert {:error, :envelope_not_in_draft} =
               Esign.add_signer(%Envelope{status: :sent}, %{})
    end
  end

  describe "add_field guards" do
    test "only draft envelopes accept new fields" do
      assert {:error, :envelope_not_in_draft} =
               Esign.add_field(%Envelope{status: :sent}, %Signer{}, %{})
    end
  end
end
