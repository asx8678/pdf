defmodule Quire.Render.CorpusTest do
  use ExUnit.Case, async: true

  @fixtures_dir Path.expand("../../fixtures/pdfs", __DIR__)
  @pdfs File.ls!(@fixtures_dir) |> Enum.filter(&String.ends_with?(&1, ".pdf"))

  # Fixtures known to fail — encrypted docs need a password, corrupt_xref
  # has intentional xref damage
  @skip MapSet.new(~w(
    encrypted_owner_pw
    encrypted_user_pw
    corrupt_xref
  ))

  for fixture <- @pdfs do
    name = fixture |> Path.rootname()
    path = Path.join(@fixtures_dir, fixture)

    if MapSet.member?(@skip, name) do
      @tag :skip
      test "page_count works for #{name}" do
        {:ok, bytes} = File.read(unquote(path))
        {:ok, ref} = Quire.Storage.put(bytes, name: unquote(fixture))
        {:ok, _count} = Quire.Render.Pdfium.page_count(ref)
      end

      @tag :skip
      test "page_geometry matches page_count for #{name}" do
        {:ok, bytes} = File.read(unquote(path))
        {:ok, ref} = Quire.Storage.put(bytes, name: unquote(fixture))
        {:ok, _pages} = Quire.Render.Pdfium.page_geometry(ref)
      end
    else
      test "page_count works for #{name}" do
        {:ok, bytes} = File.read(unquote(path))
        {:ok, ref} = Quire.Storage.put(bytes, name: unquote(fixture))
        assert {:ok, count} = Quire.Render.Pdfium.page_count(ref)
        assert is_integer(count) and count > 0
      end

      test "page_geometry matches page_count for #{name}" do
        {:ok, bytes} = File.read(unquote(path))
        {:ok, ref} = Quire.Storage.put(bytes, name: unquote(fixture))
        {:ok, count} = Quire.Render.Pdfium.page_count(ref)
        {:ok, pages} = Quire.Render.Pdfium.page_geometry(ref)
        assert length(pages) == count

        for page <- pages do
          assert is_integer(page.width)
          assert is_integer(page.height)
          assert page.rotate in [0, 90, 180, 270]
        end
      end
    end
  end
end
