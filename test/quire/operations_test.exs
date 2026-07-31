defmodule Quire.OperationsTest do
  use QuireWeb.ConnCase, async: true

  import Quire.AccountsFixtures

  alias Quire.Operations

  defp setup_doc(user) do
    %Quire.Documents.Document{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      title: "op.pdf",
      page_count: 1
    }
    |> Quire.Repo.insert!()
  end

  describe "start/progress/finish" do
    test "broadcasts monotonic progress and records the row", %{conn: conn} do
      user = user_fixture()
      doc = setup_doc(user)
      doc_id = doc.id

      Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{doc_id}")

      :telemetry.attach(
        "op-test-#{System.unique_integer([:positive])}",
        [:quire, :operation, :completed],
        fn event, _measurements, _meta, _config ->
          send(self(), {:telemetry_event, event})
        end,
        nil
      )

      {:ok, op_id} = Operations.start(doc_id, user.id, "test_conv")
      Operations.progress(op_id, doc_id, 25)
      Operations.progress(op_id, doc_id, 60)
      Operations.finish(op_id, doc_id)

      # monotonic 0 → 25 → 60 → 100 on PubSub
      assert_receive {:operation_progress, ^op_id, 0}, 1_000
      assert_receive {:operation_progress, ^op_id, 25}, 1_000
      assert_receive {:operation_progress, ^op_id, 60}, 1_000
      assert_receive {:operation_progress, ^op_id, 100}, 1_000
      assert_receive {:operation_completed, ^op_id, completed_doc_id}, 1_000
      assert completed_doc_id == doc_id

      # DB row state
      {:ok, bin} = Ecto.UUID.dump(op_id)

      rows =
        Ecto.Adapters.SQL.query!(
          Quire.Repo,
          "SELECT status, progress FROM operations WHERE id = $1",
          [bin]
        ).rows

      assert rows == [["completed", 100]]

      # duration telemetry was emitted
      assert_receive {:telemetry_event, [:quire, :operation, :completed]}, 1_000
    end

    test "fail records a plain-language cause", %{conn: conn} do
      user = user_fixture()
      doc = setup_doc(user)
      doc_id = doc.id

      Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{doc_id}")

      {:ok, op_id} = Operations.start(doc_id, user.id, "test_conv")
      Operations.fail(op_id, doc_id, {:invalid_pdf, "The file is not a readable PDF"})

      assert_receive {:operation_failed, ^op_id, ^doc_id, "The file is not a readable PDF"}, 1_000

      {:ok, bin} = Ecto.UUID.dump(op_id)

      rows =
        Ecto.Adapters.SQL.query!(
          Quire.Repo,
          "SELECT status, error FROM operations WHERE id = $1",
          [bin]
        ).rows

      assert [["failed", _]] = rows
    end
  end
end
