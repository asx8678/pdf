defmodule Quire.Office.Layout do
  @moduledoc """
  Intermediate layout model for office document conversion.

  All office readers (.docx, .xlsx, .pptx, .odt, .ods, .odp, .rtf) parse into
  this model, which is then rendered to HTML for PDF conversion via chromic_pdf
  (T-072).

  ## Versioning

  The `version` field lets downstream renderers (HTML, RTF) detect which model
  fields are present. Bump it when adding a field that changes rendering.

  ## Conversion report notes

  Unsupported constructs produce a `%{level: :unsupported, message: ..., source: ...}`
  note in the `report` list rather than being silently dropped (R-16).
  """

  defstruct version: 1,
            title: nil,
            sections: [],
            report: []

  @type note :: %{
          required(:level) => :info | :warn | :unsupported,
          required(:message) => String.t(),
          required(:source) => String.t()
        }

  @type block ::
          {:paragraph, content :: String.t()}
          | {:heading, content :: String.t(), level :: 1..6}
          | {:table, headers :: [String.t()], rows :: [[String.t()]]}
          | {:list, items :: [String.t()], ordered :: boolean()}
          | {:image, bytes :: binary(), alt :: String.t(), ext :: String.t()}

  @type t :: %__MODULE__{
          version: pos_integer(),
          title: String.t() | nil,
          sections: [Quire.Office.Layout.Section.t()],
          report: [note()]
        }

  @doc """
  Create a new empty Layout.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Add a report note.
  """
  @spec add_note(t(), atom(), String.t(), String.t()) :: t()
  def add_note(%__MODULE__{} = layout, level, message, source) do
    %{layout | report: layout.report ++ [%{level: level, message: message, source: source}]}
  end
end

defmodule Quire.Office.Layout.Section do
  @moduledoc """
  A section of an office document — a sheet (xlsx), slide (pptx) or page (docx, odt).
  """

  defstruct type: :page,
            title: nil,
            blocks: []

  @type t :: %__MODULE__{
          type: :page | :sheet | :slide,
          title: String.t() | nil,
          blocks: [Quire.Office.Layout.block()]
        }

  @doc """
  Create a new Section.
  """
  @spec new(type :: :page | :sheet | :slide, title :: String.t() | nil) :: t()
  def new(type, title \\ nil), do: %__MODULE__{type: type, title: title}

  @doc """
  Append a block to the section.
  """
  @spec add_block(t(), Quire.Office.Layout.block()) :: t()
  def add_block(%__MODULE__{} = section, block) do
    %{section | blocks: section.blocks ++ [block]}
  end
end
