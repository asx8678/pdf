defmodule Quire.Office.Writer.PptxTest do
  use ExUnit.Case, async: true

  alias Quire.Office.Layout
  alias Quire.Office.Layout.Section
  alias Quire.Office.Writer.Pptx

  describe "write/3" do
    test "returns {:ok, binary} for a valid pptx" do
      layout = Layout.new()
      {:ok, pptx} = Pptx.write(layout, :pptx)
      assert is_binary(pptx)
      assert byte_size(pptx) > 100
    end

    test "produces a valid ZIP archive" do
      layout = build_layout()
      {:ok, pptx} = Pptx.write(layout, :pptx)
      {:ok, entries} = :zip.list_dir(pptx)

      entry_names =
        Enum.flat_map(entries, fn
          {:zip_comment, _} -> []
          {:zip_file, name, _, _, _, _} -> [List.to_string(name)]
        end)

      assert "[Content_Types].xml" in entry_names
      assert "ppt/presentation.xml" in entry_names
      assert "ppt/slides/slide1.xml" in entry_names
    end

    test "renders a paragraph" do
      layout = build_layout()
      slide1 = extract_slide_xml(layout, 1)
      assert slide1 =~ "Hello from Quire"
    end

    test "renders headings" do
      section =
        Section.new(:slide)
        |> Section.add_block({:heading, "Title Slide", 1})
        |> Section.add_block({:heading, "Subtitle", 2})

      layout = %{Layout.new() | sections: [section]}
      slide1 = extract_slide_xml(layout, 1)
      assert slide1 =~ "Title Slide"
      assert slide1 =~ "Subtitle"
    end

    test "renders multiple sections as multiple slides" do
      s1 = Section.new(:slide) |> Section.add_block({:paragraph, "Slide 1"})
      s2 = Section.new(:slide) |> Section.add_block({:paragraph, "Slide 2"})
      layout = %{Layout.new() | sections: [s1, s2]}

      slide1 = extract_slide_xml(layout, 1)
      slide2 = extract_slide_xml(layout, 2)
      assert slide1 =~ "Slide 1"
      assert slide2 =~ "Slide 2"
    end

    test "renders ordered list" do
      section = Section.new(:slide) |> Section.add_block({:list, ["First", "Second"], true})
      layout = %{Layout.new() | sections: [section]}
      slide1 = extract_slide_xml(layout, 1)
      assert slide1 =~ "First"
      assert slide1 =~ "Second"
    end

    test "renders unordered list" do
      section = Section.new(:slide) |> Section.add_block({:list, ["Apples", "Oranges"], false})
      layout = %{Layout.new() | sections: [section]}
      slide1 = extract_slide_xml(layout, 1)
      assert slide1 =~ "Apples"
      assert slide1 =~ "Oranges"
    end

    test "renders table" do
      section =
        Section.new(:slide)
        |> Section.add_block({:table, ["Name", "Age"], [["Alice", "30"]]})

      layout = %{Layout.new() | sections: [section]}
      slide1 = extract_slide_xml(layout, 1)
      assert slide1 =~ "Name"
      assert slide1 =~ "Alice"
    end

    test "renders image with drawing XML" do
      section = Section.new(:slide) |> Section.add_block({:image, <<0, 1, 2>>, "test", "png"})
      layout = %{Layout.new() | sections: [section]}
      slide1 = extract_slide_xml(layout, 1)
      assert slide1 =~ "<p:pic>"
    end

    test "returns error for unsupported format" do
      layout = Layout.new()
      assert {:error, _} = Pptx.write(layout, :docx)
    end

    test "handles empty sections" do
      layout = Layout.new()
      {:ok, pptx} = Pptx.write(layout, :pptx)
      assert is_binary(pptx)
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp build_layout do
    section =
      Section.new(:slide)
      |> Section.add_block({:paragraph, "Hello from Quire!"})

    %{Layout.new() | sections: [section]}
  end

  defp extract_slide_xml(layout, n) do
    {:ok, pptx} = Pptx.write(layout, :pptx)
    name = ~c"ppt/slides/slide#{n}.xml"
    {:ok, entries} = :zip.extract(pptx, [{:file_list, [name]}, :memory])
    {^name, xml} = List.keyfind(entries, name, 0)
    xml
  end
end
