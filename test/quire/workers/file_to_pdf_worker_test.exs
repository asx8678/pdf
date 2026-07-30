defmodule Quire.Workers.FileToPdfWorkerTest do
  use ExUnit.Case, async: true

  alias Quire.Workers.FileToPdfWorker

  describe "perform/1" do
    test "returns error for unsupported format" do
      job = build_job(%{"bytes" => Base.encode64("data"), "filename" => "file.xyz"})
      assert {:error, msg} = FileToPdfWorker.perform(job)
      assert msg =~ "Unsupported"
    end

    test "returns error for unknown extension" do
      job = build_job(%{"bytes" => Base.encode64("data"), "filename" => "test.xyz"})
      assert {:error, msg} = FileToPdfWorker.perform(job)
      assert msg =~ "Unsupported"
    end
  end

  defp build_job(args) do
    %Oban.Job{
      id: 1,
      args: args,
      queue: "convert",
      worker: "Quire.Workers.FileToPdfWorker",
      max_attempts: 2,
      attempt: 1,
      inserted_at: DateTime.utc_now()
    }
  end
end
