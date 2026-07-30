defmodule QuireWeb.Chrome.RibbonSeparator do
  @moduledoc """
  Ribbon separator (plan3.md §8.3): a 1px × 44px vertical rule with
  16px horizontal margins, hidden from assistive technology.
  """
  use Phoenix.Component

  def ribbon_separator(assigns) do
    ~H"""
    <div class="w-px h-11 bg-chrome-border mx-4" aria-hidden="true" />
    """
  end
end
