defmodule Quire.Esign.EnvelopeTest do
  use ExUnit.Case, async: true
  import Ecto.Changeset

  alias Quire.Esign.Envelope

  describe "valid_transition?/2" do
    test "draft can transition to sent and draft" do
      assert Envelope.valid_transition?(:draft, :sent)
      assert Envelope.valid_transition?(:draft, :draft)
    end

    test "draft cannot transition to anything else" do
      refute Envelope.valid_transition?(:draft, :completed)
      refute Envelope.valid_transition?(:draft, :declined)
      refute Envelope.valid_transition?(:draft, :voided)
      refute Envelope.valid_transition?(:draft, :expired)
      refute Envelope.valid_transition?(:draft, :partially_signed)
    end

    test "sent can transition to partially_signed, declined, voided, expired" do
      assert Envelope.valid_transition?(:sent, :partially_signed)
      assert Envelope.valid_transition?(:sent, :declined)
      assert Envelope.valid_transition?(:sent, :voided)
      assert Envelope.valid_transition?(:sent, :expired)
    end

    test "sent cannot transition to completed or back to draft" do
      refute Envelope.valid_transition?(:sent, :completed)
      refute Envelope.valid_transition?(:sent, :draft)
    end

    test "partially_signed can transition to completed, declined, voided, expired" do
      assert Envelope.valid_transition?(:partially_signed, :completed)
      assert Envelope.valid_transition?(:partially_signed, :declined)
      assert Envelope.valid_transition?(:partially_signed, :voided)
      assert Envelope.valid_transition?(:partially_signed, :expired)
    end

    test "partially_signed cannot go back to sent" do
      refute Envelope.valid_transition?(:partially_signed, :sent)
    end

    test "terminal states have no valid outgoing transitions" do
      for state <- [:completed, :declined, :voided, :expired] do
        for target <- [:draft, :sent, :partially_signed, :completed, :declined, :voided, :expired] do
          refute Envelope.valid_transition?(state, target),
                 "#{state} should not transition to #{target}"
        end
      end
    end

    test "every declared transition in transitions/0 is valid" do
      for {from, targets} <- Envelope.transitions() do
        for to <- targets do
          assert Envelope.valid_transition?(from, to),
                 "transition #{from} -> #{to} is listed but not valid"
        end
      end
    end
  end

  describe "put_status/2" do
    test "accepts valid transitions" do
      changeset = Envelope.changeset(%Envelope{}, %{}) |> Envelope.put_status(:sent)
      refute changeset.errors[:status]
      assert get_change(changeset, :status) == :sent
    end

    test "rejects invalid transitions with an error" do
      changeset =
        %Envelope{status: :draft}
        |> Envelope.changeset(%{})
        |> Envelope.put_status(:completed)

      assert changeset.errors[:status]
      assert get_change(changeset, :status) != :completed
    end

    test "defaults from draft when no status set" do
      changeset = Envelope.changeset(%Envelope{}, %{}) |> Envelope.put_status(:sent)
      assert get_change(changeset, :status) == :sent
    end
  end
end
