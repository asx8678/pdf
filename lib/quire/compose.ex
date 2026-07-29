defmodule Quire.Compose do
  @moduledoc """
  Content-stream and appearance-stream generation behaviour (§7.2).

  Composes PDF content streams from layout models and generates `/AP`
  appearance streams for form fields. Foundation is a NIF over `Quire.Pdf`.
  """

  @doc """
  Composes a PDF content stream from a layout model.

  `layout` is a `Quire.Office.Layout.t()` or equivalent map. Returns
  content-stream bytes.
  """
  @callback compose(layout :: term(), opts :: keyword()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Generates an /AP appearance stream for an AcroForm field.

  `field` is the field metadata map; `value` is the current value to render.
  Returns appearance-stream bytes suitable for embedding in the `/AP`
  dictionary.
  """
  @callback appearance(field :: map(), value :: term(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}
end
