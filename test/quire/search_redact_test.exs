defmodule Quire.SearchRedactTest do
  use ExUnit.Case, async: true

  alias Quire.SearchRedact
  alias Quire.Storage

  @fixtures Path.expand("../fixtures/pdfs", __DIR__)

  describe "presets" do
    test "all five presets are present with labels" do
      assert SearchRedact.presets() |> length() == 5

      for {name, label, regex} <- SearchRedact.presets() do
        assert name in [:ssn, :card, :email, :phone, :iban]
        assert is_binary(label) and label != ""
        assert is_struct(regex, Regex)
      end
    end

    test "SSN preset matches known-positive and rejects known-negative" do
      regex = SearchRedact.preset_regex(:ssn)
      assert Regex.match?(regex, "123-45-6789")
      assert Regex.match?(regex, "Report SSN 987-65-4321 today")
      refute Regex.match?(regex, "12345")
      refute Regex.match?(regex, "123-45-678")
      refute Regex.match?(regex, "nothing here")
    end

    test "card preset matches 16-digit groups and rejects short numbers" do
      regex = SearchRedact.preset_regex(:card)
      assert Regex.match?(regex, "4111 1111 1111 1111")
      assert Regex.match?(regex, "4111-1111-1111-1111")
      assert Regex.match?(regex, "4111111111111111")
      refute Regex.match?(regex, "4111")
      refute Regex.match?(regex, "card number")
    end

    test "email preset matches dotted-domain addresses and rejects plain words" do
      regex = SearchRedact.preset_regex(:email)
      assert Regex.match?(regex, "jane.doe@example.com")
      assert Regex.match?(regex, "user+tag@sub.domain.co.uk")
      refute Regex.match?(regex, "not-an-email")
      refute Regex.match?(regex, "jane@localhost")
    end

    test "phone preset matches NA formats and rejects short digit runs" do
      regex = SearchRedact.preset_regex(:phone)
      assert Regex.match?(regex, "+1 (555) 123-4567")
      assert Regex.match?(regex, "555-123-4567")
      assert Regex.match?(regex, "(555) 123 4567")
      refute Regex.match?(regex, "555")
      refute Regex.match?(regex, "12345")
    end

    test "IBAN preset matches ISO 13616 and rejects short alphanumerics" do
      regex = SearchRedact.preset_regex(:iban)
      assert Regex.match?(regex, "GB82WEST12345698765432")
      assert Regex.match?(regex, "DE89 3704 0044 0532 0130 00")
      refute Regex.match?(regex, "GB82")
      refute Regex.match?(regex, "notaniban")
    end

    test "preset_label/1 returns the human label and nil for unknown" do
      assert SearchRedact.preset_label(:ssn) == "Social Security Number"
      assert SearchRedact.preset_label("email") == "Email address"
      assert SearchRedact.preset_label(:nope) == nil
    end
  end

  describe "search/3" do
    setup do
      bytes = File.read!(Path.join(@fixtures, "simple_text.pdf"))
      {:ok, ref} = Storage.put(bytes, name: "simple.pdf", content_type: "application/pdf")
      %{ref: ref}
    end

    test "literal search is case-sensitive by default", %{ref: ref} do
      assert {:ok, []} = SearchRedact.search(ref, "world", [])
      assert {:ok, hits} = SearchRedact.search(ref, "World", [])
      assert [hit] = hits
      assert hit.text == "World"
      assert hit.page == 0
      assert [left, bottom, right, top] = hit.rect
      assert right > left and top > bottom
      assert hit.snippet =~ "Hello World"
      assert is_binary(hit.id)
    end

    test "regex search with inline flag matches case-insensitively", %{ref: ref} do
      assert {:ok, hits} = SearchRedact.search(ref, "(?i)hello", regex: true)
      assert [hit] = hits
      assert hit.text == "Hello"
    end

    test "literal search escapes regex metacharacters", %{ref: ref} do
      # A literal "." must not match every character.
      assert {:ok, []} = SearchRedact.search(ref, "W.rld", [])
    end

    test "invalid regex returns an error tuple", %{ref: ref} do
      assert {:error, {:invalid_regex, _msg}} = SearchRedact.search(ref, "[", regex: true)
    end

    test "empty query returns no hits", %{ref: ref} do
      assert {:ok, []} = SearchRedact.search(ref, "", [])
    end
  end

  describe "search_preset/2" do
    setup do
      bytes = File.read!(Path.join(@fixtures, "simple_text.pdf"))
      {:ok, ref} = Storage.put(bytes, name: "simple.pdf", content_type: "application/pdf")
      %{ref: ref}
    end

    test "unknown preset is an error" do
      assert {:error, :unknown_preset} = SearchRedact.search_preset(%Storage.Ref{}, :nope)
    end

    test "known preset runs and tags hits", %{ref: ref} do
      # simple_text.pdf has no PII — a preset search must return cleanly with
      # zero hits rather than crashing.
      assert {:ok, hits} = SearchRedact.search_preset(ref, :ssn)
      assert hits == []
    end
  end

  describe "marks_for_hits/2" do
    test "full hit maps become marks" do
      hits = [
        %{id: "a", page: 0, rect: [1, 2, 3, 4], text: "x"},
        %{id: "b", page: 1, rect: [5, 6, 7, 8], text: "y"}
      ]

      assert SearchRedact.marks_for_hits(hits) == [
               %{page: 0, rect: [1, 2, 3, 4]},
               %{page: 1, rect: [5, 6, 7, 8]}
             ]
    end

    test "id references resolve against all_hits" do
      hits = [
        %{id: "a", page: 0, rect: [1, 2, 3, 4], text: "x"},
        %{id: "b", page: 1, rect: [5, 6, 7, 8], text: "y"}
      ]

      assert SearchRedact.marks_for_hits([%{"id" => "b"}], hits) == [
               %{page: 1, rect: [5, 6, 7, 8]}
             ]
    end

    test "duplicate marks are deduplicated" do
      hits = [
        %{id: "a", page: 0, rect: [1, 2, 3, 4], text: "x"},
        %{id: "b", page: 0, rect: [1, 2, 3, 4], text: "x"}
      ]

      assert SearchRedact.marks_for_hits(hits) == [%{page: 0, rect: [1, 2, 3, 4]}]
    end

    test "unknown ids and junk entries are dropped" do
      assert SearchRedact.marks_for_hits([%{"id" => "zzz"}], [
               %{id: "a", page: 0, rect: [1, 2, 3, 4]}
             ]) ==
               []

      assert SearchRedact.marks_for_hits([%{"page" => 0, "rect" => [1, 2, 3, 4]}]) == [
               %{page: 0, rect: [1, 2, 3, 4]}
             ]
    end
  end
end
