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

  describe "text_to_html/1" do
    test "wraps plain text in HTML document" do
      html = FileToPdfWorker.text_to_html("hello world")
      assert html =~ "<html"
      assert html =~ "</html>"
      assert html =~ "<pre>"
      assert html =~ "hello world"
      assert html =~ "</pre>"
    end

    test "preserves whitespace and line breaks" do
      text = "line one\n\nline three"
      html = FileToPdfWorker.text_to_html(text)
      assert html =~ "line one"
      assert html =~ "line three"
      assert html =~ "white-space:pre-wrap"
    end

    test "escapes HTML special characters" do
      html = FileToPdfWorker.text_to_html("<script>alert('xss')</script>")
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "format routing" do
    test "accepts .txt extension" do
      assert :text == FileToPdfWorker.classify_ext(".txt")
    end

    test "accepts .csv extension" do
      assert :text == FileToPdfWorker.classify_ext(".csv")
    end

    test "accepts .md extension" do
      assert :text == FileToPdfWorker.classify_ext(".md")
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
