defmodule Quire.Accounts.UserSetting do
  @moduledoc """
  Per-user settings stored in the `user_settings` table.

  There is at most one row per user (enforced by a unique index on
  `user_id`).  `user_id` is set programmatically — never from untrusted
  input.
  """

  use Quire.Schema
  import Ecto.Changeset

  schema "user_settings" do
    belongs_to :user, Quire.Accounts.User
    field :theme, :string, default: "system"
    field :default_zoom, :float, default: 1.0
    field :default_view_mode, :string, default: "single"
    field :ruler_visible, :boolean, default: true
    field :grid_visible, :boolean, default: false

    field :qat_items, :map
    field :signatures, :map
    field :stamps, :map

    field :recent_limit, :integer, default: 20
    field :ocr_default_lang, :string, default: "eng"
    field :measurement_unit, :string, default: "mm"
    field :autosave_enabled, :boolean, default: true

    timestamps()
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :theme,
      :default_zoom,
      :default_view_mode,
      :ruler_visible,
      :grid_visible,
      :qat_items,
      :signatures,
      :stamps,
      :recent_limit,
      :ocr_default_lang,
      :measurement_unit,
      :autosave_enabled
    ])
    |> validate_inclusion(:theme, ["system", "light", "dark"])
    |> validate_number(:default_zoom, greater_than: 0.1, less_than: 5.0)
    |> validate_number(:recent_limit, greater_than: 0, less_than: 101)
    |> set_default_qat_items()
  end

  defp set_default_qat_items(changeset) do
    case fetch_change(changeset, :qat_items) do
      {:ok, _val} ->
        changeset

      :error ->
        default = [
          %{"id" => "undo", "label" => "Undo", "enabled" => true},
          %{"id" => "redo", "label" => "Redo", "enabled" => true},
          %{"id" => "open", "label" => "Open", "enabled" => true},
          %{"id" => "save", "label" => "Save", "enabled" => true},
          %{"id" => "print", "label" => "Print", "enabled" => true},
          %{"id" => "email", "label" => "Email", "enabled" => true},
          %{"id" => "new", "label" => "New", "enabled" => true}
        ]

        put_change(changeset, :qat_items, default)
    end
  end

  @doc """
  Creates or updates user settings for a user.

  `user_id` is set programmatically and is never taken from `attrs`.
  """
  def upsert(setting, attrs, user_id) do
    setting
    |> changeset(attrs)
    |> put_change(:user_id, user_id)
    |> Quire.Repo.insert_or_update()
  end
end
