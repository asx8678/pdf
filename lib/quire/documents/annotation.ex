defmodule Quire.Documents.Annotation do
  @moduledoc """
  A persisted annotation on a document revision (§5.3).

  Stores annotation data (quad points, color, opacity, content) that can
  be embedded into the PDF on the next save via the annot.add editing op.
  """
  use Quire.Schema

  @kind_values ~w(highlight underline strikethrough squiggly sticky_note free_text free_text_callout ink stamp signature line arrow double_arrow dimension oval rectangle polygon cloud polyline file_attachment measure_distance measure_perimeter measure_area whiteout)

  schema "annotations" do
    field :revision_id, :binary_id
    field :page_index, :integer
    field :kind, :string
    field :rect, :map
    field :quad_points, :map
    field :path_data, :map
    field :color, :map
    field :opacity, :float
    field :border_width, :float
    field :content, :string
    field :author, :string
    field :attachment_ref, :map

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(annotation, attrs) do
    annotation
    |> Ecto.Changeset.cast(attrs, [
      :revision_id,
      :page_index,
      :kind,
      :rect,
      :quad_points,
      :path_data,
      :color,
      :opacity,
      :border_width,
      :content,
      :author,
      :attachment_ref
    ])
    |> Ecto.Changeset.validate_required([:revision_id, :page_index, :kind])
    |> Ecto.Changeset.validate_inclusion(:kind, @kind_values)
  end
end
