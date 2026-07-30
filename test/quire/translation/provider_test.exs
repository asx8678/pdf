defmodule Quire.Translation.ProviderTest do
  use ExUnit.Case, async: true

  alias Quire.Translation.Provider
  alias Quire.Translation.Provider.Result
  alias Quire.Translation.Provider.Null

  describe "Provider.Null" do
    test "returns the source text unchanged" do
      assert {:ok, result} = Null.translate("Hello world", "en", "de")
      assert result.translated_text == "Hello world"
    end

    test "returns a translation disabled banner" do
      assert {:ok, result} = Null.translate("Hello", "en", "es")
      assert result.banner =~ "Translation disabled"
      assert result.banner =~ "configure a provider"
    end

    test "handles multilingual text" do
      text = "Hello, こんにちは, Привет"
      assert {:ok, result} = Null.translate(text, "detect", "fr")
      assert result.translated_text == text
    end
  end

  describe "Provider.configured/1" do
    test "defaults to Null" do
      assert Provider.configured() == Null
    end
  end

  describe "Provider.translate/3 delegation" do
    test "delegates to configured provider" do
      assert {:ok, result} = Provider.translate("test", "en", "fr")
      assert result.translated_text == "test"
    end
  end

  describe "Provider.cache_key/3" do
    test "produces consistent SHA-256 keys" do
      key1 = Provider.cache_key("hello", "en", "fr")
      key2 = Provider.cache_key("hello", "en", "fr")
      key3 = Provider.cache_key("hello", "en", "de")

      assert key1 == key2
      assert key1 != key3
      assert String.match?(key1, ~r/^[a-f0-9]{64}$/)
    end
  end

  describe "Result struct" do
    test "has required fields" do
      result = %Result{translated_text: "hola", source_lang: "en", target_lang: "es"}
      assert result.translated_text == "hola"
      assert result.banner == nil
    end

    test "accepts banner field" do
      result = %Result{
        translated_text: "hola",
        source_lang: "en",
        target_lang: "es",
        banner: "disabled"
      }

      assert result.banner == "disabled"
    end
  end
end
