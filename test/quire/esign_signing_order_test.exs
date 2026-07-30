defmodule Quire.EsignSigningOrderTest do
  use Quire.DataCase, async: false

  alias Quire.Esign
  alias Quire.Esign.{Envelope, Signer}

  describe "can_signer_access?/2" do
    setup do
      user = user_fixture()
      doc = document_fixture(user)
      %{user: user, doc: doc}
    end

    test "parallel mode allows all signers", %{user: user, doc: doc} do
      envelope =
        insert_envelope(%{owner_id: user.id, document_id: doc.id, signing_mode: :parallel})

      signer = insert_signer(envelope, %{order: 1})

      assert Esign.can_signer_access?(envelope, signer)
    end

    test "sequential mode blocks out-of-order signers", %{user: user, doc: doc} do
      envelope =
        insert_envelope(%{owner_id: user.id, document_id: doc.id, signing_mode: :sequential})

      signer1 = insert_signer(envelope, %{order: 1, status: :pending})
      signer2 = insert_signer(envelope, %{order: 2, status: :pending})

      assert Esign.can_signer_access?(envelope, signer1)
      refute Esign.can_signer_access?(envelope, signer2)
    end

    test "sequential mode allows next signer after previous signs", %{user: user, doc: doc} do
      envelope =
        insert_envelope(%{owner_id: user.id, document_id: doc.id, signing_mode: :sequential})

      signer1 = insert_signer(envelope, %{order: 1, status: :pending})
      signer2 = insert_signer(envelope, %{order: 2, status: :pending})

      {:ok, signed1} =
        signer1
        |> Signer.changeset(%{})
        |> Signer.put_status(:viewed)
        |> Quire.Repo.update!()
        |> then(fn s ->
          Signer.changeset(s, %{}) |> Signer.put_status(:signed) |> Quire.Repo.update()
        end)

      refute Esign.can_signer_access?(envelope, signer1)
      assert Esign.can_signer_access?(envelope, signer2)
    end

    test "sequential mode with 3 signers: progressive access", %{user: user, doc: doc} do
      envelope =
        insert_envelope(%{owner_id: user.id, document_id: doc.id, signing_mode: :sequential})

      s1 = insert_signer(envelope, %{order: 1, status: :pending})
      s2 = insert_signer(envelope, %{order: 2, status: :pending})
      _s3 = insert_signer(envelope, %{order: 3, status: :pending})

      assert Esign.can_signer_access?(envelope, s1)
      refute Esign.can_signer_access?(envelope, s2)

      {:ok, _} =
        s1
        |> Signer.changeset(%{})
        |> Signer.put_status(:viewed)
        |> Quire.Repo.update!()
        |> then(fn s ->
          Signer.changeset(s, %{}) |> Signer.put_status(:signed) |> Quire.Repo.update()
        end)

      assert Esign.can_signer_access?(envelope, s2)
    end
  end

  defp user_fixture do
    %Quire.Accounts.User{
      id: Ecto.UUID.generate(),
      email: "user-#{System.unique_integer([:positive])}@example.com",
      hashed_password: "not_a_real_hash"
    }
    |> Quire.Repo.insert!()
  end

  defp document_fixture(user) do
    %Quire.Documents.Document{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      title: "test.pdf"
    }
    |> Quire.Repo.insert!()
  end

  defp insert_envelope(attrs \\ %{}) do
    defaults = %{
      document_id: Ecto.UUID.generate(),
      owner_id: Ecto.UUID.generate(),
      subject: "Please sign these docs",
      status: :sent,
      signing_mode: :sequential
    }

    attrs = Enum.into(attrs, defaults)

    %Envelope{}
    |> Envelope.changeset(attrs)
    |> Quire.Repo.insert!()
  end

  defp insert_signer(envelope, attrs \\ %{}) do
    %Signer{
      envelope_id: envelope.id,
      name: "Test Signer",
      email: "test@example.com",
      order: 1,
      status: :pending
    }
    |> Signer.changeset(attrs)
    |> Quire.Repo.insert!()
  end
end
