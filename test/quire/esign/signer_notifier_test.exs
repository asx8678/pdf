defmodule Quire.Esign.SignerNotifierTest do
  use ExUnit.Case, async: true

  alias Quire.Esign.SignerNotifier

  describe "deliver_invitation/5" do
    test "sends invitation with signing link" do
      {:ok, email} =
        SignerNotifier.deliver_invitation(
          "signer@example.com",
          "Alice",
          "Contract v2",
          "Bob",
          "https://quire.app/sign/abc123"
        )

      assert email.to == [{"", "signer@example.com"}]
      assert email.from == {"Quire", "noreply@quire.app"}
      assert email.subject == "Please sign: Contract v2"
      assert String.contains?(email.text_body, "https://quire.app/sign/abc123")
      assert String.contains?(email.text_body, "Alice")
      assert String.contains?(email.text_body, "Bob")
    end

    test "uses default subject when envelope subject is nil" do
      {:ok, email} = SignerNotifier.deliver_invitation("a@b.com", "Alice", nil, "Bob", "https://quire.app/sign/x")
      assert email.subject == "Please sign: Document"
    end
  end

  describe "deliver_reminder/5" do
    test "sends reminder email" do
      {:ok, email} =
        SignerNotifier.deliver_reminder(
          "signer@example.com",
          "Alice",
          "NDA",
          "Bob",
          "https://quire.app/sign/abc123"
        )

      assert email.subject == "Reminder: NDA still needs your signature"
      assert String.contains?(email.text_body, "https://quire.app/sign/abc123")
    end
  end

  describe "deliver_completion/3" do
    test "sends completion notification to owner" do
      {:ok, email} = SignerNotifier.deliver_completion("owner@example.com", "Bob", "Contract v2")
      assert email.subject == "All signatures collected for: Contract v2"
    end
  end

  describe "deliver_decline/4" do
    test "sends decline notification to owner" do
      {:ok, email} = SignerNotifier.deliver_decline("owner@example.com", "Bob", "Contract v2", "Alice")
      assert email.subject == "Alice declined: Contract v2"
    end
  end
end
