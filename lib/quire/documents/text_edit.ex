defmodule Quire.Documents.TextEdit do
  @moduledoc """
  A tracked Edit-tab content change (plan3.md §5.3 `text_edits`).

  One row per app-applied mark (page number, watermark, header/footer,
  Bates) or content change (add text, edit text, insert image, link).
  `kind` mirrors the `text_edits` column contract
  (`:page_number`, `:watermark`, `:header_footer`, `:bates`, …).

  `content` carries the per-row mark data so T-098 can enumerate and
  remove exactly the marks this app applied.
  """
  use Quire.Schema

  @kinds ~w(add_text edit_text insert_image link page_number watermark header_footer bates)

  schema "text_edits" do
    field :document_id, :binary_id
    field :page_index, :integer
    field :kind, :string
    field :rect, :map
    field :style, :map
    field :content, :map
    field :applied_revision_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(text_edit, attrs) do
    text_edit
    |> Ecto.Changeset.cast(attrs, [
      :document_id,
      :page_index,
      :kind,
      :rect,
      :style,
      :content,
      :applied_revision_id
    ])
    |> Ecto.Changeset.validate_required([:document_id, :kind])
  end

  @doc "The valid `text_edits` kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds
end
