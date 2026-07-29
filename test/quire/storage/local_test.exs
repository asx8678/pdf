defmodule Quire.Storage.LocalTest do
  use ExUnit.Case, async: false

  import Quire.StorageCase

  alias Quire.Storage
  alias Quire.Storage.Ref
  alias Quire.Storage.Local

  setup do
    tmp_root = storage_tmp_root!()
    on_exit(fn -> File.rm_rf!(tmp_root) end)
    Application.put_env(:quire, :data_dir, tmp_root)

    restore_adapter = adapter_setup(adapter())
    on_exit(restore_adapter)

    :ok
  end

  defp adapter, do: Local

  # ── Shared StorageCase suite (identical structure in WebTest) ──────────

  describe "shared suite" do
    test "exports all callbacks" do
      callbacks = Storage.behaviour_info(:callbacks)
      assert length(callbacks) == 12

      for {name, arity} <- callbacks do
        assert function_exported?(adapter(), name, arity),
               "expected #{inspect(adapter())} to export #{name}/#{arity}"
      end
    end

    test "put + get round-trip" do
      data = "hello storage"
      assert {:ok, ref} = Storage.put(data, put_opts(adapter(), data))
      assert {:ok, ^data} = Storage.get(ref)
    end

    test "put + delete" do
      assert {:ok, ref} = Storage.put("delete me", put_opts(adapter(), "delete me"))
      assert :ok = Storage.delete(ref)
      assert {:error, _} = Storage.get(ref)
    end

    test "size" do
      s = String.duplicate("s", 100)
      assert {:ok, ref} = Storage.put(s, put_opts(adapter(), s))
      assert {:ok, 100} = Storage.size(ref)
    end

    test "name" do
      opts = put_opts(adapter(), "named") |> Keyword.put(:name, "doc.pdf")
      assert {:ok, ref} = Storage.put("named", opts)
      assert Storage.name(ref) == "doc.pdf"
    end

    test "with_local_path" do
      data = "local-path data"
      assert {:ok, ref} = Storage.put(data, put_opts(adapter(), data))

      Storage.with_local_path(ref, fn path ->
        assert is_binary(path)
        assert File.exists?(path)
        assert File.read!(path) == data
      end)
    end

    test "with_local_paths" do
      assert {:ok, r1} = Storage.put("a", put_opts(adapter(), "a"))
      assert {:ok, r2} = Storage.put("b", put_opts(adapter(), "b"))

      Storage.with_local_paths([r1, r2], fn paths ->
        assert length(paths) == 2
        assert File.read!(Enum.at(paths, 0)) == "a"
        assert File.read!(Enum.at(paths, 1)) == "b"
      end)
    end

    test "stream" do
      data = String.duplicate("x", 10_000)
      assert {:ok, ref} = Storage.put(data, put_opts(adapter(), data))
      result = Storage.stream(ref, 4_096) |> Enum.join()
      assert result == data
    end

    test "scratch dir cleanup" do
      dir_path =
        Storage.with_scratch_dir("test", fn dir ->
          assert File.exists?(dir)
          File.write!(Path.join(dir, "test.txt"), "scratch")
          dir
        end)

      refute File.exists?(dir_path)
    end

    test "scratch dir crash cleanup" do
      assert_raise RuntimeError, fn ->
        Storage.with_scratch_dir("crash", fn _dir -> raise "runtime error" end)
      end
    end

    test "pick_open and pick_save unsupported" do
      assert Storage.pick_open() == {:error, :unsupported}
      assert Storage.pick_save() == {:error, :unsupported}
    end
  end

  # ── Local-specific tests ────────────────────────────────────────────────

  describe "absolute path key" do
    test "Ref.key is the absolute path passed in opts" do
      tmp_root = Application.get_env(:quire, :data_dir) || System.tmp_dir!()
      target_path = Path.join(tmp_root, "custom_location.bin")

      assert {:ok, %Ref{key: ^target_path}} =
               Storage.put("content", path: target_path, name: "custom.bin")
    end

    test "put returns error without opts[:path]" do
      assert {:error, :path_required} = Storage.put("data", name: "no-path.txt")
    end

    test "absolute path resolves on get" do
      tmp_root = Application.get_env(:quire, :data_dir) || System.tmp_dir!()
      target_path = Path.join(tmp_root, "resolvable.bin")

      assert {:ok, ref} = Storage.put("accessible", path: target_path, name: "r.bin")
      assert {:ok, "accessible"} = Storage.get(ref)
    end
  end

  describe "with_local_path is zero-copy" do
    test "path is the original absolute path" do
      tmp_root = Application.get_env(:quire, :data_dir) || System.tmp_dir!()
      target_path = Path.join(tmp_root, "zero_copy.bin")

      assert {:ok, ref} = Storage.put("data", path: target_path, name: "z.bin")

      Storage.with_local_path(ref, fn path ->
        assert path == target_path
        assert File.exists?(path)
      end)
    end
  end

  describe "edge cases" do
    test "get returns error for missing file" do
      ref = %Ref{
        adapter: Local,
        key: "/tmp/nonexistent_#{:rand.uniform(1_000_000)}.dat",
        name: "missing.dat"
      }

      assert {:error, _} = Storage.get(ref)
    end

    test "list_dir returns entries" do
      tmp_root = Application.get_env(:quire, :data_dir) || System.tmp_dir!()

      dir = Path.join(tmp_root, "list_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "a.txt"), "a")
      File.write!(Path.join(dir, "b.txt"), "b")

      on_exit(fn -> File.rm_rf!(dir) end)

      dir_ref = %Ref{adapter: Local, key: dir, name: "list_test"}
      assert {:ok, entries} = Storage.list_dir(dir_ref)
      assert length(entries) == 2

      names = Enum.map(entries, & &1.name) |> MapSet.new()
      assert MapSet.member?(names, "a.txt")
      assert MapSet.member?(names, "b.txt")
    end
  end
end
