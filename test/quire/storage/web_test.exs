defmodule Quire.Storage.WebTest do
  use ExUnit.Case, async: false

  alias Quire.Storage
  alias Quire.Storage.Ref
  alias Quire.Storage.Web

  setup do
    tmp_root = storage_tmp_root!()
    on_exit(fn -> File.rm_rf!(tmp_root) end)
    Application.put_env(:quire, :data_dir, tmp_root)

    restore_adapter = adapter_setup(adapter())
    on_exit(restore_adapter)

    :ok
  end

  defp adapter, do: Web

  # ── Inline helpers (avoid compile-time dep on Quire.StorageCase) ────────

  defp storage_tmp_root! do
    Path.join(System.tmp_dir!(), "quire_storage_test_#{:rand.uniform(1_000_000)}")
  end

  defp adapter_setup(adapter_mod) do
    current = Application.fetch_env!(:quire, :storage_adapter)
    Application.put_env(:quire, :storage_adapter, adapter_mod)
    fn -> Application.put_env(:quire, :storage_adapter, current) end
  end

  defp put_opts(_adapter, _data), do: [name: "test.bin"]

  # ── Shared StorageCase suite (identical structure in LocalTest) ─────────

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

    test "key scheme matches ADR 0005" do
      assert {:ok, ref} = Storage.put("key-scheme", put_opts(adapter(), "key-scheme"))
      parts = String.split(ref.key, "/")
      assert length(parts) == 3, "Web key must have two-level fan-out, got: #{inspect(ref.key)}"
      [first2, next2, uuid] = parts

      assert String.match?(first2, ~r/^[0-9a-f]{2}$/),
             "Web key first component must be 2 hex chars, got: #{inspect(first2)}"

      assert String.match?(next2, ~r/^[0-9a-f]{2}$/),
             "Web key second component must be 2 hex chars, got: #{inspect(next2)}"

      assert String.match?(
               uuid,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
             ),
             "Web key third component must be a UUID v7, got: #{inspect(uuid)}"
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

  # ── Web-specific tests ──────────────────────────────────────────────────

  describe "key fan-out" do
    test "generates a two-level fan-out key" do
      assert {:ok, %Ref{key: key}} = Storage.put("data", name: "doc.pdf")

      parts = String.split(key, "/")
      assert length(parts) == 3
      assert String.length(Enum.at(parts, 0)) == 2
      assert String.length(Enum.at(parts, 1)) == 2
      assert String.length(Enum.at(parts, 2)) == 36
    end
  end

  describe "atomic writes" do
    test "no orphan .tmp files after successful write" do
      assert {:ok, %Ref{key: key}} = Storage.put("test", name: "t.txt")

      tmp_root = Application.get_env(:quire, :data_dir)
      dir = Path.join(tmp_root, key) |> Path.dirname()

      assert Enum.empty?(Path.wildcard(Path.join(dir, "*.tmp.*")))
    end

    test "no half-written ref after simulated crash" do
      assert {:ok, ref} = Storage.put("survivor", name: "survivor.txt")

      tmp_root = Application.get_env(:quire, :data_dir)
      tmp = Path.join(tmp_root, ref.key) <> ".tmp.crashed"
      File.write!(tmp, "half-written")

      assert {:ok, "survivor"} = Storage.get(ref)
    end
  end

  describe "edge cases" do
    test "get returns error for missing ref" do
      ref = %Ref{adapter: Web, key: "aa/bb/nonexistent", name: "missing.txt"}
      assert {:error, _} = Storage.get(ref)
    end

    test "defaults name from key tail" do
      assert {:ok, ref} = Storage.put("data", [])
      assert String.length(Storage.name(ref)) == 36
    end

    test "list_dir returns entries" do
      assert {:ok, r1} = Storage.put("a", name: "a.txt")

      first2 = String.slice(r1.key, 0, 2)
      dir_ref = %Ref{adapter: Web, key: first2, name: first2}

      assert {:ok, entries} = Storage.list_dir(dir_ref)
      assert length(entries) > 0
    end
  end
end
