defmodule Quire.Translation.Provider do
  @moduledoc """
  Behaviour for translation providers.

  Implementations translate text from one language to another and return a
  `Quire.Translation.Result` struct. The default provider is
  `Quire.Translation.Provider.Null`, which returns the source text unchanged
  with a visible "translation disabled" banner — licensed costs never hit a
  fresh clone's test suite.

  Swap providers in config:

      config :quire, :translation_provider, MyApp.Provider.Custom

  ## Callbacks

  Implement `translate/3` (source/target languages are strings like `"en"`,
  `"de"`, `"ja"`). Return `{:ok, %Result{}}` or `{:error, reason}`.

  ## Estimated cost

  Providers SHOULD implement `estimate_cost/1` to return a human-readable
  cost estimate before translation runs. The default implementation returns
  `:unknown`.
  """

  alias Quire.Translation.Provider

  @doc """
  Translates `text` from `source_lang` to `target_lang`.

  Returns `{:ok, %Result{translated_text: ..., ...}}` or
  `{:error, reason}`.
  """
  @callback translate(String.t(), source_lang :: String.t(), target_lang :: String.t()) ::
              {:ok, Result.t()} | {:error, String.t()}

  @doc """
  Estimates the cost of translating `text` from `source_lang` to `target_lang`.

  Returns `{:ok, description_string}` or `:unknown`.
  """
  @callback estimate_cost(String.t(), source_lang :: String.t(), target_lang :: String.t()) ::
              {:ok, String.t()} | :unknown

  @optional_callbacks estimate_cost: 3

  @doc """
  Returns the configured provider module.
  """
  @spec configured() :: module()
  def configured do
    Application.get_env(:quire, :translation_provider, Provider.Null)
  end

  @doc """
  Delegates `translate/3` to the configured provider.
  """
  @spec translate(String.t(), String.t(), String.t()) ::
          {:ok, Result.t()} | {:error, String.t()}
  def translate(text, source_lang, target_lang) do
    configured().translate(text, source_lang, target_lang)
  end

  @doc """
  Returns cost estimate from the configured provider, or `:unknown`.
  """
  @spec estimate_cost(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :unknown
  def estimate_cost(text, source_lang, target_lang) do
    configured().estimate_cost(text, source_lang, target_lang)
  rescue
    _ -> :unknown
  end

  @doc """
  Builds the translation cache key for the given text and language pair.
  """
  @spec cache_key(String.t(), String.t(), String.t()) :: String.t()
  def cache_key(text, source_lang, target_lang) do
    :crypto.hash(:sha256, "#{text}|#{source_lang}|#{target_lang}") |> Base.encode16(case: :lower)
  end
end
