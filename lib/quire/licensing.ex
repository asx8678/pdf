defmodule Quire.Licensing do
  @moduledoc """
  Licensing tiers and feature gating (§11.2, T-164).

  | Tier       | Features                                                                 |
  |------------|--------------------------------------------------------------------------|
  | Trial      | Everything, watermarked output on export, 14-day limit                  |
  | Standard   | Everything in Core + Edit + Comment + Fill & Sign + Secure              |
  | Premium    | Everything in Standard + E-Sign + OCR + Translate                       |
  | Business   | Everything in Premium + Desktop + Cloud + SSO + Audit                   |

  ## Gating

  Features MUST be gated in **three** places (never rely on hiding UI alone):

    1. The component — `<.gated feature={:ocr}>` renders an upsell overlay.
    2. The LiveView event handler — returns a licensing error instead of acting.
    3. The Oban worker — fails the job with a licensing error before processing.

  ## Usage

      iex> Quire.Licensing.allows?(%User{tier: "trial"}, :ocr)
      true

      iex> Quire.Licensing.allows?(%User{tier: "trial"}, :cloud_sync)
      false
  """

  @typedoc "One of the four defined tiers"
  @type tier :: String.t()

  @typedoc "A feature key recognised by the gating system"
  @type feature ::
          :edit
          | :comment
          | :fill_sign
          | :secure
          | :ocr
          | :esign
          | :translate
          | :desktop
          | :cloud_sync
          | :sso
          | :audit
          | :export

  @doc """
  Tier-to-feature mapping.

  Each tier lists the features it unlocks. Features not listed are denied.
  """
  @tier_features %{
    "trial" => [
      :edit,
      :comment,
      :fill_sign,
      :secure,
      :ocr,
      :export
    ],
    "standard" => [
      :edit,
      :comment,
      :fill_sign,
      :secure,
      :export
    ],
    "premium" => [
      :edit,
      :comment,
      :fill_sign,
      :secure,
      :esign,
      :ocr,
      :translate,
      :export
    ],
    "business" => [
      :edit,
      :comment,
      :fill_sign,
      :secure,
      :esign,
      :ocr,
      :translate,
      :desktop,
      :cloud_sync,
      :sso,
      :audit,
      :export
    ]
  }

  @doc """
  Returns `true` if the user's tier includes the given feature.

  Accepts a `User` struct (or `%Scope{}` with a `.user` field), a raw tier
  string, or `nil` (treated as trial/guest).

  The look-up chain is:
    1. If the user has a preloaded `.license` association, read `.license.tier`.
    2. Otherwise query the `licenses` table for the user's active license.
    3. If no license exists, default to `"trial"`.
  """
  @spec allows?(map() | nil, feature()) :: boolean()
  def allows?(nil, feature) do
    allows?("trial", feature)
  end

  def allows?(%{user: %{id: _id} = user}, feature) do
    allows?(user, feature)
  end

  # User with preloaded license
  def allows?(%{id: _id, license: %{tier: tier}}, feature) do
    allows?(tier, feature)
  end

  # User with no preloaded license but has an id — query DB
  def allows?(%{id: id}, feature) when is_binary(id) do
    tier = resolve_user_tier(id)
    allows?(tier, feature)
  end

  def allows?(tier, feature) when is_binary(tier) do
    tier = if tier in Map.keys(@tier_features), do: tier, else: "standard"

    Map.get(@tier_features, tier, [])
    |> Enum.member?(feature)
  end

  defp resolve_user_tier(user_id) do
    import Ecto.Query

    query =
      from(l in Quire.Accounts.License,
        where: l.user_id == ^user_id,
        order_by: [desc: l.inserted_at],
        limit: 1,
        select: l.tier
      )

    case Quire.Repo.one(query) do
      nil -> "trial"
      tier -> tier
    end
  end

  @doc """
  Returns the user-facing refusal message for a denied feature.
  """
  @spec refusal_message(feature()) :: String.t()
  def refusal_message(_feature) do
    "This feature requires a higher licensing tier. Please upgrade to access it."
  end

  @doc """
  List of all recognised tiers in ascending order.
  """
  @spec tiers() :: [tier()]
  def tiers, do: ["trial", "standard", "premium", "business"]
end
