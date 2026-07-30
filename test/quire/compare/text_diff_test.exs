defmodule Quire.Compare.TextDiffTest do
  use ExUnit.Case, async: true

  alias Quire.Compare.TextDiff
  alias Quire.Compare.TextDiff.Change

  describe "compare_pages/2" do
    test "identical pages produce no changes" do
      pages_a = [
        %{
          spans: [
            %{
              text: "hello world",
              bounds: %{left: 0, top: 0, right: 50, bottom: 10},
              page_index: 0
            }
          ]
        }
      ]

      pages_b = [
        %{
          spans: [
            %{
              text: "hello world",
              bounds: %{left: 0, top: 0, right: 50, bottom: 10},
              page_index: 0
            }
          ]
        }
      ]

      result = TextDiff.compare_pages(pages_a, pages_b)
      assert result.changes == []
    end

    test "detects deleted text" do
      pages_a = [
        %{
          spans: [
            %{
              text: "hello world goodbye",
              bounds: %{left: 0, top: 0, right: 100, bottom: 10},
              page_index: 0
            }
          ]
        }
      ]

      pages_b = [
        %{
          spans: [
            %{
              text: "hello world",
              bounds: %{left: 0, top: 0, right: 50, bottom: 10},
              page_index: 0
            }
          ]
        }
      ]

      result = TextDiff.compare_pages(pages_a, pages_b)
      deletions = Enum.filter(result.changes, &(&1.class == :deleted))
      assert length(deletions) > 0
      assert Enum.any?(deletions, &(&1.text =~ "goodbye"))
    end

    test "detects inserted text" do
      pages_a = [
        %{
          spans: [
            %{
              text: "hello world",
              bounds: %{left: 0, top: 0, right: 50, bottom: 10},
              page_index: 0
            }
          ]
        }
      ]

      pages_b = [
        %{
          spans: [
            %{
              text: "hello wonderful world",
              bounds: %{left: 0, top: 0, right: 100, bottom: 10},
              page_index: 0
            }
          ]
        }
      ]

      result = TextDiff.compare_pages(pages_a, pages_b)
      insertions = Enum.filter(result.changes, &(&1.class == :inserted))
      assert length(insertions) > 0
      assert Enum.any?(insertions, &(&1.text =~ "wonderful"))
    end

    test "empty pages produce no changes" do
      result = TextDiff.compare_pages([%{spans: []}], [%{spans: []}])
      assert result.changes == []
    end

    test "page count mismatch handles missing pages" do
      pages_a = [
        %{spans: [%{text: "page one", bounds: %{}, page_index: 0}]},
        %{spans: [%{text: "page two", bounds: %{}, page_index: 1}]}
      ]

      pages_b = [
        %{spans: [%{text: "page one", bounds: %{}, page_index: 0}]}
      ]

      result = TextDiff.compare_pages(pages_a, pages_b)
      assert length(result.pages) == 1
    end

    test "case-insensitive matching" do
      pages_a = [
        %{spans: [%{text: "Hello World", bounds: %{}, page_index: 0}]}
      ]

      pages_b = [
        %{spans: [%{text: "hello world", bounds: %{}, page_index: 0}]}
      ]

      result = TextDiff.compare_pages(pages_a, pages_b)
      assert result.changes == []
    end
  end

  describe "Change struct" do
    test "stores class, text, rects" do
      change = %Change{
        class: :inserted,
        text: "new text",
        rects: [%{x: 0, y: 0}],
        page_a: nil,
        page_b: 1
      }

      assert change.class == :inserted
      assert change.text == "new text"
      assert change.rects == [%{x: 0, y: 0}]
    end
  end
end
