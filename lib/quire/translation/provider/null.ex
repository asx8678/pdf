defmodule Quire.Translation.Provider.Null do
  @moduledoc """
  Default translation provider.

  Returns the source text unchanged with a visible "translation disabled"
  banner. This ensures a fresh clone runs the entire test suite with zero
  network calls and zero billing.
  """

  @behaviour Quire.Translation.Provider

  @impl true
  def translate(text, _source_lang, _target_lang) do
    {:ok, %Quire.Translation.Provider.Result{
      translated_text: text,
      source_lang: "detect",
      target_lang: "detect",
      banner: "Translation disabled — configure a provider in config.exs"
    }}
  end

  @impl true
  def estimate_cost(_text, _source_lang, _target_lang), do: :unknown
end
