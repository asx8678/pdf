defmodule Quire.Ocr.Results do
  @moduledoc ~S"""
  Ecto schema for the `ocr_results` table (§5.5).

  Stores per-page confidence data (aggregated from Tesseract per-word confidences)
  and metadata about an OCR run.  Created once per OCR pipeline invocation.

  `page_confidences` is a JSONB map keyed by zero-based page index:
      %{
        0 => %{
          avg: 92.5,
          min: 45.0,
          word_count: 128,
          words: [%{word: "hello", conf: 95}, …]
        },
        …
      }

  The `words` list is stored for detailed inspection but may be truncated
  for very dense pages.
  """

  use Quire.Schema

  schema "ocr_results" do
    field :document_id, :binary_id
    field :revision_id, :binary_id
    field :languages, {:array, :string}
    field :engine_version, :string
    field :page_confidences, :map, default: %{}
    field :threshold, :float, default: 80.0
    field :options, :map, default: %{}
    field :searchable, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: binary(),
          document_id: binary(),
          revision_id: binary(),
          languages: [String.t()] | nil,
          engine_version: String.t() | nil,
          page_confidences: map(),
          threshold: float(),
          options: map(),
          searchable: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Finds the most recent OcrResult for a given document.
  """
  @spec latest_by_document(binary()) :: t() | nil
  def latest_by_document(document_id) do
    import Ecto.Query

    query =
      from(r in __MODULE__,
        where: r.document_id == ^document_id,
        order_by: [desc: r.inserted_at],
        limit: 1
      )

    Quire.Repo.one(query)
  end

  @doc """
  Finds the OcrResult associated with a specific revision.
  """
  @spec by_revision(binary()) :: t() | nil
  def by_revision(revision_id) do
    import Ecto.Query

    query =
      from(r in __MODULE__,
        where: r.revision_id == ^revision_id,
        limit: 1
      )

    Quire.Repo.one(query)
  end
end
