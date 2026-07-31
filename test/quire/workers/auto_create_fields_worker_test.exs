defmodule Quire.Workers.AutoCreateFieldsWorkerTest do
  use Quire.DataCase, async: false

  alias Quire.Workers.AutoCreateFieldsWorker
  alias Quire.Documents.{Document, Revision}
  alias Quire.Repo

  @scanned Path.expand("../../fixtures/pdfs/scanned_300dpi.pdf", __DIR__)

  setup do
    user =
      %Quire.Accounts.User{
        id: Ecto.UUID.generate(),
        email: "user-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "x"
      }
      |> Repo.insert!()

    %{user: user}
  end

  defp document_fixture(user) do
    doc =
      %Document{id: Ecto.UUID.generate(), user_id: user.id, title: "scanned.pdf", page_count: 1}
      |> Repo.insert!()

    {:ok, ref} = Quire.Storage.put(File.read!(@scanned), name: "scanned.pdf")

    source_map = %{
      "storage_ref" => %{
        "adapter" => to_string(ref.adapter),
        "key" => ref.key,
        "name" => ref.name,
        "content_type" => ref.content_type,
        "byte_size" => ref.byte_size
      },
      "filename" => "scanned.pdf"
    }

    rev =
      %Revision{
        id: Ecto.UUID.generate(),
        document_id: doc.id,
        label: "Original upload",
        source: source_map
      }
      |> Repo.insert!()

    doc =
      doc
      |> Ecto.Changeset.change(%{current_revision_id: rev.id})
      |> Repo.update!()

    %{doc: doc, rev: rev}
  end

  defp job(args), do: %Oban.Job{args: args}

  describe "perform/1" do
    test "returns :not_found for an unknown revision" do
      assert {:error, :not_found} =
               AutoCreateFieldsWorker.perform(
                 job(%{
                   "doc_id" => Ecto.UUID.generate(),
                   "revision_id" => Ecto.UUID.generate(),
                   "operation_id" => Ecto.UUID.generate()
                 })
               )
    end

    test "returns :not_found for a document without a stored revision", %{user: user} do
      doc =
        %Document{
          id: Ecto.UUID.generate(),
          user_id: user.id,
          title: "no-rev.pdf",
          page_count: 1
        }
        |> Repo.insert!()

      assert {:error, :not_found} =
               AutoCreateFieldsWorker.perform(
                 job(%{
                   "doc_id" => doc.id,
                   "revision_id" => Ecto.UUID.generate(),
                   "operation_id" => Ecto.UUID.generate()
                 })
               )
    end

    test "detects fields and broadcasts them for the document topic", %{user: user} do
      %{doc: doc, rev: rev} = document_fixture(user)

      Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{doc.id}")
      op_id = Ecto.UUID.generate()

      assert :ok =
               AutoCreateFieldsWorker.perform(
                 job(%{
                   "doc_id" => doc.id,
                   "revision_id" => rev.id,
                   "operation_id" => op_id
                 })
               )

      assert_receive {:auto_create_detections, ^op_id, %{total: 5, fields: fields}}, 15_000
      assert length(fields) == 5
      assert Enum.all?(fields, &(&1.page_index == 0))
    end
  end
end
