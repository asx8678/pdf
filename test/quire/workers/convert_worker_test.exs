defmodule Quire.Workers.ConvertWorkerTest do
  use Quire.DataCase, async: true

  alias Quire.Workers.ConvertWorker

  # These tests verify the worker's structure and error paths without
  # driving Chromium.  Full integration tests that exercise chromic_pdf
  # carry @moduletag :serial (§13).
  #
  # Run with: mix test test/quire/workers/convert_worker_test.exs
  # Serial pass: mix test --max-cases 1 test/.../convert_worker_test.exs:tag

  describe "job construction" do
    test "new/1 creates a changeset" do
      changeset = ConvertWorker.new(%{source_type: "html"})
      assert changeset.valid?
      assert changeset.changes[:queue] == "convert"
    end

    test "new/1 sets max_attempts" do
      changeset = ConvertWorker.new(%{source_type: "html"})
      assert changeset.changes[:max_attempts] == 2
    end
  end

  describe "perform/1 validation" do
    test "rejects unknown source_type" do
      job = build_job(%{"source_type" => "gopher"})
      assert {:error, msg} = ConvertWorker.perform(job)
      assert msg =~ "Unknown source_type"
    end
  end

  defp build_job(args) do
    %Oban.Job{args: args}
  end
end
