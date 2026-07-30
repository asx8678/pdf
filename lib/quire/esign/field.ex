defmodule Quire.Esign.Field do
  @moduledoc """
  A signature field placed on a page for a specific signer.
  """

  use Quire.Schema
  import Ecto.Changeset

  schema "esign_fields" do
    field :envelope_id, :binary_id
    field :signer_id, :binary_id
    field :page_index, :integer
    field :rect, :map
    field :kind, Ecto.Enum, values: [:signature, :initials, :name, :date, :text, :checkbox]
    field :required, :boolean, default: false
    field :value, :string

    belongs_to :envelope, Quire.Esign.Envelope, define_field: false
    belongs_to :signer, Quire.Esign.Signer, define_field: false
  end

  @doc false
  def changeset(field, attrs) do
    field
    |> cast(attrs, [:envelope_id, :signer_id, :page_index, :rect, :kind, :required, :value])
    |> validate_required([:envelope_id, :signer_id, :page_index, :rect, :kind])
    |> validate_inclusion(:page_index, 0..9999)
  end
end
