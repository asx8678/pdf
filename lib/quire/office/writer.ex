defmodule Quire.Office.Writer do
  @moduledoc """
  Office document writing behaviour (§7.2).

  Implementations produce office-format bytes from a `Quire.Office.Layout.t()`.
  Supported output formats mirror the reader's input formats.
  """

  @doc """
  Writes an office document from a layout.

  `layout` is a `Quire.Office.Layout.t()`. `format` is an atom such as
  `:docx`, `:xlsx`, or `:odt`. Returns document bytes.
  """
  @callback write(layout :: term(), format :: atom(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Returns the list of output formats this writer supports.
  """
  @callback supported_formats() :: list(atom())
end
