defmodule Quire.Storage.WebTest do
  use ExUnit.Case, async: true

  alias Quire.Storage
  alias Quire.Storage.Ref
  alias Quire.Storage.Web

  setup do
    tmp_root = Path.join(System.tmp_dir!(), "quire_web_test_#{:rand.uniform(1_000_000)}")

    on_exit(fn ->
      File.rm_rf!(tmp_root)
    end)

    Application.put_env(:quire, :data_dir, tmp_root)

    on_exit(fn ->
      Application.delete_env(:quire, :data_dir)
    end)

    {:ok, tmp_root: tmp_root}
  end

  describe "behaviour implementation" do
    test "exports all 11 callbacks" do
      callbacks = Quire.Storage.behaviour_info(:callbacks)

      for {name, arity} <- callbacks do
        assert function_exported?(Web, name, arity),
               "expected #{inspect(Web)} to export #{name}/#{arity}"
      end
    end
  end

  describe "put/2" do
    test "stores data and returns a ref" do
      assert {:ok, %Ref{} = ref} = Storage.put("hello world", name: "test.txt")
      assert ref.name == "test.txt"
      assert ref.byte_size == 11
      assert ref.adapter == Web
    end

    test "generates a two-level fan-out key" do
      assert {:ok, %Ref{key: key}} = Storage.put("data", name: "doc.pdf")

      parts = String.split(key, "/")
      assert length(parts) == 3
      assert String.length(Enum.at(parts, 0)) == 2
      assert String.length(Enum.at(parts, 1)) == 2
      assert String.length(Enum.at(parts, 2)) == 36
    end

    test "stores under configurable root" do
      tmp_root = Application.get_env(:quire, :data_dir)
      assert {:ok, %Ref{key: key}} = Storage.put("content", name: "f.txt")

      full_path = Path.join(tmp_root, key)
      assert File.exists?(full_path)
      assert File.read!(full_path) == "content"
    end

    test "writes to temp file then renames into place" do
      assert {:ok, %Ref{key: key}} = Storage.put("test", name: "t.txt")

      tmp_root = Application.get_env(:quire, :data_dir)
      dir = Path.join(tmp_root, key) |> Path.dirname()

      assert Enum.empty?(Path.wildcard(Path.join(dir, "*.tmp.*"))),
             "expected no orphan .tmp files after successful write"
    end
  end

  describe "get/1" do
    test "retrieves stored data" do
      assert {:ok, ref} = Storage.put("hello world", name: "test.txt")
      assert {:ok, data} = Storage.get(ref)
      assert data == "hello world"
    end

    test "returns error for non-existent ref" do
      ref = %Ref{adapter: Web, key: "aa/bb/nonexistent", name: "missing.txt"}
      assert {:error, _} = Storage.get(ref)
    end
  end

  describe "stream/2" do
    test "streams stored data in chunks" do
      content = String.duplicate("x", 100_000)
      assert {:ok, ref} = Storage.put(content, name: "large.bin")

      result = Storage.stream(ref, 16_384) |> Enum.join()
      assert String.length(result) == 100_000
      assert result == content
    end
  end

  describe "delete/1" do
    test "deletes stored data" do
      assert {:ok, ref} = Storage.put("delete me", name: "gone.txt")
      assert :ok = Storage.delete(ref)
      assert {:error, _} = Storage.get(ref)
    end
  end

  describe "size/1" do
    test "returns byte size" do
      assert {:ok, ref} = Storage.put("1234567890", name: "ten.txt")
      assert {:ok, 10} = Storage.size(ref)
    end
  end

  describe "name/1" do
    test "returns the human-facing name" do
      assert {:ok, ref} = Storage.put("data", name: "my-report.pdf")
      assert Storage.name(ref) == "my-report.pdf"
    end

    test "defaults name from key tail when not provided" do
      assert {:ok, ref} = Storage.put("data", [])
      assert String.valid?(Storage.name(ref))
      assert String.length(Storage.name(ref)) == 36
    end
  end

  describe "with_local_path/2" do
    test "hands over the real path (zero-copy)" do
      assert {:ok, ref} = Storage.put("file content", name: "real-path.txt")

      Storage.with_local_path(ref, fn path ->
        assert is_binary(path)
        assert String.starts_with?(path, Application.get_env(:quire, :data_dir))
        assert File.exists?(path)
        assert File.read!(path) == "file content"
      end)
    end
  end

  describe "with_local_paths/2" do
    test "materialises multiple refs" do
      assert {:ok, r1} = Storage.put("a", name: "a.txt")
      assert {:ok, r2} = Storage.put("b", name: "b.txt")

      Storage.with_local_paths([r1, r2], fn paths ->
        assert length(paths) == 2
        assert File.read!(Enum.at(paths, 0)) == "a"
        assert File.read!(Enum.at(paths, 1)) == "b"
      end)
    end
  end

  describe "with_scratch_dir/2" do
    test "creates and cleans up a scratch directory" do
      dir_path =
        Storage.with_scratch_dir("test-purpose", fn dir ->
          assert File.exists?(dir)
          File.write!(Path.join(dir, "test.txt"), "scratch")
          dir
        end)

      refute File.exists?(dir_path),
             "expected scratch dir to be cleaned up after use"
    end

    test "cleans up even when the function raises" do
      assert_raise RuntimeError, "boom", fn ->
        Storage.with_scratch_dir("crash", fn _dir ->
          raise "boom"
        end)
      end
    end
  end

  describe "pick_open/1 pick_save/1" do
    test "pick_open returns {:error, :unsupported}" do
      assert Storage.pick_open() == {:error, :unsupported}
    end

    test "pick_save returns {:error, :unsupported}" do
      assert Storage.pick_save() == {:error, :unsupported}
    end
  end

  describe "list_dir/1" do
    test "lists entries in a directory ref" do
      assert {:ok, r1} = Storage.put("a", name: "a.txt")

      first2 = String.slice(r1.key, 0, 2)
      dir_ref = %Ref{adapter: Web, key: first2, name: first2}

      assert {:ok, entries} = Storage.list_dir(dir_ref)
      assert length(entries) > 0
    end
  end

  describe "crash mid-write" do
    test "no half-written ref is readable after simulated crash" do
      assert {:ok, ref} = Storage.put("survivor", name: "survivor.txt")
      assert {:ok, "survivor"} = Storage.get(ref)

      tmp_root = Application.get_env(:quire, :data_dir)
      full_path = Path.join(tmp_root, ref.key)

      # Simulate a crashed write: temp file exists but was never renamed
      tmp = full_path <> ".tmp.crashed"
      File.write!(tmp, "half-written")

      # Storage should still return the survivor content, not the temp
      assert {:ok, data} = Storage.get(ref)
      assert data == "survivor", "expected survivor content, not half-written temp"
    end
  end
end
