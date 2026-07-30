defmodule QuireWeb.ActivateModal do
  @moduledoc """
  LiveComponent for the "Activate now" modal (§11.2, T-165).

  Accepts an activation key, validates it against the `licenses` table, and
  upgrades the current user's tier on success.
  """

  use QuireWeb, :live_component

  alias Quire.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="activate-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
      phx-click="close_activate"
      phx-window-keydown="close_activate"
      phx-key="escape"
    >
      <div
        class="bg-white dark:bg-gray-800 rounded-xl shadow-2xl max-w-md w-full mx-4 p-6"
        phx-click-away="close_activate"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold text-gray-900 dark:text-gray-100">
            Activate Now
          </h2>
          <button
            phx-click="close_activate"
            class="text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 transition-colors cursor-pointer"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <p class="text-sm text-gray-600 dark:text-gray-400 mb-4">
          Enter your activation key to unlock additional features.
        </p>

        <!-- Current tier badge -->
        <div class="mb-4 px-3 py-2 bg-gray-50 dark:bg-gray-700/50 rounded-lg text-xs text-gray-500 dark:text-gray-400">
          Current plan: <span class="font-medium text-gray-700 dark:text-gray-200 capitalize">{@current_tier}</span>
        </div>

        <.form
          for={@form}
          id="activate-form"
          phx-submit="activate"
          phx-target={@myself}
          class="space-y-4"
        >
          <.input
            field={@form[:activation_key]}
            type="text"
            label="Activation key"
            placeholder="XXXXX-XXXXX-XXXXX-XXXXX"
            autocomplete="off"
            required
            class="text-center tracking-widest font-mono"
          />

          <.button
            type="submit"
            class="w-full"
            phx-disable-with="Validating..."
          >
            Activate
          </.button>
        </.form>

        <p :if={@error} class="mt-3 text-sm text-red-600 dark:text-red-400 text-center">
          {@error}
        </p>

        <p :if={@success} class="mt-3 text-sm text-green-600 dark:text-green-400 text-center">
          {@success}
        </p>
      </div>
    </div>
    """
  end

  @impl true
  def update(%{current_scope: scope} = assigns, socket) do
    form = socket.assigns[:form] || to_form(%{"activation_key" => ""}, as: :license)

    socket =
      socket
      |> assign(assigns)
      |> assign(:form, form)
      |> assign(:error, socket.assigns[:error])
      |> assign(:success, socket.assigns[:success])
      |> assign(:current_tier, Quire.Licensing.current_tier(scope))

    {:ok, socket}
  end

  @impl true
  def handle_event("activate", %{"license" => %{"activation_key" => key}}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.validate_activation_key(user, key) do
      {:ok, %{tier: tier}} ->
        {:noreply,
         socket
         |> assign(:form, to_form(%{"activation_key" => ""}, as: :license))
         |> assign(:error, nil)
         |> assign(:success, "Activated! Your plan has been upgraded to #{tier}.")
         |> assign(:current_tier, tier)}

      {:error, reason} ->
        {:noreply, socket |> assign(:error, reason) |> assign(:success, nil)}
    end
  end
end
