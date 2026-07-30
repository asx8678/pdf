defmodule Quire.Translation.Provider.Result do
  @moduledoc """
  The result of a translation call.

  Fields:

    * `translated_text` — the translated text
    * `source_lang` — detected or provided source language
    * `target_lang` — target language
    * `banner` — set to a non-nil string when the provider wants to show a
      visible banner (e.g. "Translation disabled" for the Null provider)
  """

  defstruct [:translated_text, :source_lang, :target_lang, :banner]

  @type t :: %__MODULE__{
          translated_text: String.t(),
          source_lang: String.t(),
          target_lang: String.t(),
          banner: String.t() | nil
        }
end
