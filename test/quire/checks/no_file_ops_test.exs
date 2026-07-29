defmodule Quire.Checks.NoFileOpsTest do
  use Credo.Test.Case

  alias Quire.Checks.NoFileOps

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "Path.t() typespec" do
    test "Path.t() does not trigger (typespec, not a call)" do
      """
      defmodule Foo do
        @spec process(Path.t()) :: :ok
        def process(_path), do: :ok
      end
      """
      |> to_source_file("lib/quire/documents.ex")
      |> run_check(NoFileOps)
      |> refute_issues()
    end
  end

  describe "Path.join/2 call" do
    test "Path.join/2 in non-exempt file triggers" do
      """
      defmodule Foo do
        def run, do: Path.join("/a", "b")
      end
      """
      |> to_source_file("lib/quire/documents.ex")
      |> run_check(NoFileOps)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Path."
        assert issue.message =~ "File/Path/System"
      end)
    end
  end

  describe "File.read/1 call" do
    test "File.read/1 in non-exempt file triggers" do
      """
      defmodule Foo do
        def run, do: File.read("/etc/hosts")
      end
      """
      |> to_source_file("lib/quire/documents.ex")
      |> run_check(NoFileOps)
      |> assert_issue(fn issue ->
        assert issue.trigger == "File."
      end)
    end
  end

  describe "System.cmd call" do
    test "System.cmd in non-exempt file triggers" do
      """
      defmodule Foo do
        def run, do: System.cmd("ls", ["-la"])
      end
      """
      |> to_source_file("lib/quire/documents.ex")
      |> run_check(NoFileOps)
      |> assert_issue(fn issue ->
        assert issue.trigger == "System.cmd"
      end)
    end
  end

  describe "System.tmp_dir call" do
    test "System.tmp_dir in non-exempt file triggers" do
      """
      defmodule Foo do
        def run, do: dir = System.tmp_dir!()
      end
      """
      |> to_source_file("lib/quire/documents.ex")
      |> run_check(NoFileOps)
      |> assert_issue(fn issue ->
        assert issue.trigger == "System.tmp_dir"
      end)
    end
  end

  describe "exempt files" do
    test "lib/quire/storage/ files are exempt" do
      """
      def run, do: File.read("/etc/hosts")
      """
      |> to_source_file("lib/quire/storage/web/filesystem.ex")
      |> run_check(NoFileOps)
      |> refute_issues()
    end

    test "lib/quire/storage.ex is exempt" do
      """
      def run, do: File.read("/etc/hosts")
      """
      |> to_source_file("lib/quire/storage.ex")
      |> run_check(NoFileOps)
      |> refute_issues()
    end

    test "lib/quire/engine.ex is exempt" do
      """
      def run, do: File.read("/etc/hosts")
      """
      |> to_source_file("lib/quire/engine.ex")
      |> run_check(NoFileOps)
      |> refute_issues()
    end

    test "lib/quire/checks/ files are exempt" do
      """
      def run, do: File.read("/etc/hosts")
      """
      |> to_source_file("lib/quire/checks/some_check.ex")
      |> run_check(NoFileOps)
      |> refute_issues()
    end

    test "test/support/ files are exempt" do
      """
      def run, do: File.read("/etc/hosts")
      """
      |> to_source_file("test/support/my_helper.ex")
      |> run_check(NoFileOps)
      |> refute_issues()
    end
  end

  describe "non-exempt files" do
    test "lib/quire/documents.ex is NOT exempt" do
      """
      def run, do: File.read("/etc/hosts")
      """
      |> to_source_file("lib/quire/documents.ex")
      |> run_check(NoFileOps)
      |> assert_issue()
    end
  end

  describe "clean files" do
    test "file with no File/Path/System calls returns no issues" do
      """
      defmodule Clean do
        def run, do: :ok
      end
      """
      |> to_source_file("lib/quire/documents.ex")
      |> run_check(NoFileOps)
      |> refute_issues()
    end
  end
end
