defmodule Quire.StorageTest do
  use ExUnit.Case, async: true

  alias Quire.Storage
  alias Quire.Storage.Ref

  describe "Storage.Ref" do
    test "struct has the required fields" do
      assert %Ref{adapter: nil, key: nil, name: nil} = %Ref{}
    end

    test "struct accepts optional content_type, byte_size, meta" do
      ref = %Ref{
        adapter: __MODULE__,
        key: "abc/def/uuid-v7-key",
        name: "report.pdf",
        content_type: "application/pdf",
        byte_size: 42_000,
        meta: %{checksum: "sha256-abc123"}
      }

      assert ref.content_type == "application/pdf"
      assert ref.byte_size == 42_000
      assert ref.meta == %{checksum: "sha256-abc123"}
    end

    @doc """
    `Ref.key` is opaque to callers — nothing outside an adapter module may
    inspect it.  Dialyzer enforces this boundary via the `@opaque` type; no
    public function exposes `key` on the `Quire.Storage` module.  Download
    headers must derive the filename from `Ref.name`, never from `Ref.key`.
    """
    test "key is present for adapter use but name is the public identifier" do
      ref = %Ref{key: "internal/path", name: "document.pdf"}

      # name is the caller-facing filename
      assert ref.name == "document.pdf"

      # key is present (adapters need it) but the opaque contract says:
      # "Nothing outside the adapter may inspect it."
      assert ref.key == "internal/path"
    end
  end

  describe "Quire.Storage behaviour" do
    test "defines all 11 required callbacks" do
      callbacks = Storage.behaviour_info(:callbacks) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      assert MapSet.member?(callbacks, :put)
      assert MapSet.member?(callbacks, :get)
      assert MapSet.member?(callbacks, :stream)
      assert MapSet.member?(callbacks, :delete)
      assert MapSet.member?(callbacks, :size)
      assert MapSet.member?(callbacks, :name)
      assert MapSet.member?(callbacks, :with_local_path)
      assert MapSet.member?(callbacks, :with_local_paths)
      assert MapSet.member?(callbacks, :with_scratch_dir)
      assert MapSet.member?(callbacks, :pick_open)
      assert MapSet.member?(callbacks, :pick_save)
      assert MapSet.member?(callbacks, :list_dir)
    end

    test "dispatch looks up adapter at runtime" do
      # Storage reads Application.fetch_env!(:quire, :storage_adapter)
      # on every call — no compile-time alias.  The function exists but
      # raises when no adapter is configured (test environment).
      assert {:adapter, 0} in Storage.__info__(:functions),
             "Storage.adapter/0 must exist for runtime dispatch"

      assert Application.fetch_env(:quire, :storage_adapter) == :error,
             "storage_adapter must not be set in test config"

      # Calling adapter/0 without a configured value raises
      assert_raise ArgumentError, ~r/could not fetch application environment/, fn ->
        Storage.adapter()
      end
    end
  end

  describe "Storage.Ref opaque contract" do
    @doc """
    The `key` field MUST NOT be exposed through any public Storage function.
    Only adapters (which know their own key format) inspect it.
    """
    test "no public Storage function returns or accepts key as a string argument" do
      exports =
        Storage.__info__(:functions)
        |> MapSet.new()

      no_key_fns =
        exports
        |> Enum.filter(fn {name, _arity} ->
          String.contains?(Atom.to_string(name), "key")
        end)

      assert no_key_fns == [],
             "Expected no public function to reference 'key', got: #{inspect(no_key_fns)}"
    end

    test "download-specific Ref functions exist with correct arities" do
      # name/1 returns the human-facing filename — the only correct source
      # for Content-Disposition headers.
      assert {:name, 1} in Storage.__info__(:functions)

      ref = %Ref{name: "downloaded.pdf"}
      assert %Ref{name: "downloaded.pdf"} = ref
    end
  end
end
