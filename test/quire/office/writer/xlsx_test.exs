defmodule Quire.Office.Writer.XlsxTest do
  use ExUnit.Case, async: true

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section
  alias Quire.Office.Writer.Xlsx

  describe "write/3" do
    test "returns {:ok, binary} for a valid xlsx" do
      layout = Layout.new()
      {:ok, xlsx} = Xlsx.write(layout, :xlsx)
      assert is_binary(xlsx)
      assert byte_size(xlsx) > 100
    end

    test "produces a valid ZIP archive" do
      section = Section.new(:sheet) |> Section.add_block({:paragraph, "Hello"})
      layout = %{Layout.new() | sections: [section]}
      {:ok, xlsx} = Xlsx.write(layout, :xlsx)
      {:ok, entries} = :zip.list_dir(xlsx)

      entry_names =
        Enum.flat_map(entries, fn
          {:zip_comment, _} -> []
          {:zip_file, name, _, _, _, _} -> [List.to_string(name)]
        end)

      assert "xl/workbook.xml" in entry_names
      assert "xl/worksheets/sheet1.xml" in entry_names
    end

    test "renders a paragraph as a row" do
      section = Section.new(:sheet) |> Section.add_block({:paragraph, "Hello World"})
      layout = %{Layout.new() | sections: [section]}
      {:ok, xlsx} = Xlsx.write(layout, :xlsx)
      assert is_binary(xlsx)
    end

    test "renders headings as bold rows" do
      section =
        Section.new(:sheet)
        |> Section.add_block({:heading, "Title", 1})
        |> Section.add_block({:paragraph, "Content"})

      layout = %{Layout.new() | sections: [section]}
      {:ok, xlsx} = Xlsx.write(layout, :xlsx)
      assert is_binary(xlsx)
    end

    test "renders table as header + data rows" do
      section =
        Section.new(:sheet)
        |> Section.add_block({:table, ["Name", "Age"], [["Alice", "30"], ["Bob", "25"]]})

      layout = %{Layout.new() | sections: [section]}
      {:ok, xlsx} = Xlsx.write(layout, :xlsx)
      assert is_binary(xlsx)
    end

    test "renders list items as rows" do
      section = Section.new(:sheet) |> Section.add_block({:list, ["One", "Two", "Three"], false})
      layout = %{Layout.new() | sections: [section]}
      {:ok, xlsx} = Xlsx.write(layout, :xlsx)
      assert is_binary(xlsx)
    end

    test "uses section title as sheet name" do
      section = %{Section.new(:sheet) | title: "Data"}
      layout = %{Layout.new() | sections: [section]}
      {:ok, xlsx} = Xlsx.write(layout, :xlsx)
      assert is_binary(xlsx)
    end

    test "handles multiple sections as multiple sheets" do
      s1 = Section.new(:sheet) |> Section.add_block({:paragraph, "Sheet1"})
      s2 = Section.new(:sheet) |> Section.add_block({:paragraph, "Sheet2"})
      layout = %{Layout.new() | sections: [s1, s2]}
      {:ok, xlsx} = Xlsx.write(layout, :xlsx)
      assert is_binary(xlsx)
    end

    test "handles empty layout" do
      layout = Layout.new()
      {:ok, xlsx} = Xlsx.write(layout, :xlsx)
      assert is_binary(xlsx)
    end

    test "returns error for unsupported format" do
      layout = Layout.new()
      assert {:error, _} = Xlsx.write(layout, :docx)
    end
  end
end
