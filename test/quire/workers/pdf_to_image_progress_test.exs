defmodule Quire.Workers.PdfToImageProgressTest do
  use QuireWeb.ConnCase, async: true

  import Quire.AccountsFixtures

  alias Quire.Repo
  alias Quire.Documents.{Document, Revision}

  @fixtures Path.expand("../../fixtures/pdfs", __DIR__)

  describe "long conversion progress (T-086)" do
    @tag timeout: 90_000
    test "a real PDF→Image conversion broadcasts monotonic progress on PubSub" do
      user = user_fixture()
      bytes = File.read!(Path.join(@fixtures, "500_pages.pdf"))
      {:ok, ref} = Quire.Storage.put(bytes, name: "500.pdf", content_type: "application/pdf")

      doc =
        %Document{id: Ecto.UUID.generate(), user_id: user.id, title: "500.pdf", page_count: 500}
        |> Repo.insert!()

      source_map = %{
        "storage_ref" => %{
          "adapter" => to_string(ref.adapter),
          "key" => ref.key,
          "name" => ref.name,
          "content_type" => ref.content_type,
          "byte_size" => ref.byte_size
        },
        "filename" => "500.pdf"
      }

      rev =
        %Revision{document_id: doc.id, label: "Original", source: source_map}
        |> Repo.insert!()

      doc
      |> Ecto.Changeset.change(%{current_revision_id: rev.id})
      |> Repo.update!()

      Phoenix.PubSub.subscribe(Quire.PubSub, "document:#{doc.id}")

      # attach telemetry before the conversion runs
      :telemetry.attach(
        "op-dur-#{System.unique_integer([:positive])}",
        [:quire, :operation, :completed],
        fn event, _measurements, _meta, _config -> send(self(), {:telemetry_event, event}) end,
        nil
      )

      # run the worker synchronously in a Task (it is Oban-free when called
      # directly, like the other worker tests in this suite)
      {_us, result} =
        :timer.tc(fn ->
          Quire.Workers.PdfToImageWorker.perform(%Oban.Job{
            args: %{
              "doc_id" => doc.id,
              "revision_id" => rev.id,
              "format" => "png",
              "dpi" => 300,
              "page_range" => Enum.to_list(0..9)
            }
          })
        end)

      assert result == :ok

      # collect the progress broadcasts and assert they are monotonic
      progresses =
        Stream.repeatedly(fn ->
          receive do
            {:operation_progress, _op_id, pct} -> pct
            {:operation_completed, op_id, _doc_id} -> {:completed, op_id}
          after
            10_000 -> :timeout
          end
        end)
        |> Enum.take_while(fn
          {:completed, _} -> false
          :timeout -> false
          _ -> true
        end)

      assert progresses != []
      assert progresses == Enum.sort(progresses), "progress must be monotonic"
      assert List.last(progresses) >= 90

      # the operation row reached completed
      {:ok, bin} = Ecto.UUID.dump(doc.id)

      rows =
        Ecto.Adapters.SQL.query!(
          Quire.Repo,
          "SELECT status, progress FROM operations WHERE document_id = $1",
          [bin]
        ).rows

      assert rows == [["completed", 100]]

      # telemetry was emitted for the duration
      assert_receive {:telemetry_event, [:quire, :operation, :completed]}, 5_000
    end
  end
end
