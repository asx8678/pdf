defmodule Quire.Repo.Migrations.AddAnnotationShapeFields do
  use Ecto.Migration

  def up do
    alter table(:annotations) do
      add :path_data, :map
      add :rect, :map
      add :border_width, :float
      add :author, :string
    end
  end

  def down do
    alter table(:annotations) do
      remove :path_data
      remove :rect
      remove :border_width
      remove :author
    end
  end
end
