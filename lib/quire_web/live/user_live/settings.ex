defmodule QuireWeb.UserLive.Settings do
  use QuireWeb, :live_view

  on_mount {QuireWeb.UserAuth, :require_sudo_mode}

  alias Quire.Accounts

  @known_languages %{
    "eng" => "English",
    "fra" => "French",
    "deu" => "German",
    "spa" => "Spanish",
    "ita" => "Italian",
    "por" => "Portuguese",
    "nld" => "Dutch",
    "dan" => "Danish",
    "swe" => "Swedish",
    "nor" => "Norwegian",
    "fin" => "Finnish",
    "ron" => "Romanian",
    "ces" => "Czech",
    "pol" => "Polish",
    "ukr" => "Ukrainian",
    "rus" => "Russian",
    "ara" => "Arabic",
    "hin" => "Hindi",
    "chi_sim" => "Chinese (Simplified)",
    "chi_tra" => "Chinese (Traditional)",
    "jpn" => "Japanese",
    "kor" => "Korean",
    "tha" => "Thai",
    "vie" => "Vietnamese",
    "tur" => "Turkish",
    "ell" => "Greek",
    "heb" => "Hebrew"
  }

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <hr class="my-8 border-chrome-border dark:border-gray-700" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <hr class="my-8 border-chrome-border dark:border-gray-700" />

      <!-- OCR Tessdata Management -->
      <div>
        <.header>
          OCR Languages
          <:subtitle>Manage downloaded language packs for text recognition</:subtitle>
        </.header>

        <div class="mt-4 space-y-4">
          <!-- Disk usage -->
          <div class="flex items-center justify-between px-4 py-3 bg-gray-50 dark:bg-gray-800/50 rounded-lg">
            <span class="text-sm text-gray-700 dark:text-gray-200">Disk usage</span>
            <span class="text-sm font-mono text-gray-600 dark:text-gray-400">
              {format_bytes(@disk_usage)}
            </span>
          </div>

          <!-- Installed languages -->
          <div :if={@cached_languages != []}>
            <h3 class="text-xs font-semibold text-gray-700 dark:text-gray-200 mb-2 uppercase tracking-wide">
              Downloaded language packs
            </h3>
            <div class="space-y-1">
              <div
                :for={lang <- @cached_languages}
                class="flex items-center justify-between px-3 py-2 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
              >
                <span class="text-sm text-gray-700 dark:text-gray-200">
                  {language_label(lang)}
                  <span class="text-xs text-gray-400 dark:text-gray-500 ml-1">({lang})</span>
                </span>
                <button
                  type="button"
                  phx-click="remove_language"
                  phx-value-lang={lang}
                  aria-label="Remove {language_label(lang)}"
                  class="inline-flex items-center gap-1 px-2 py-1 text-xs font-medium rounded-md border border-chrome-border dark:border-gray-600 text-gray-500 dark:text-gray-400 hover:text-red-600 dark:hover:text-red-400 hover:border-red-300 dark:hover:border-red-700 transition-colors cursor-pointer"
                >
                  <.icon name="hero-trash" class="size-3.5" /> Remove
                </button>
              </div>
            </div>
          </div>

          <p :if={@cached_languages == []} class="text-sm text-gray-500 dark:text-gray-400 italic">
            No language packs have been downloaded. Select a language in the OCR options panel to download it.
          </p>

          <!-- Remove All -->
          <div :if={@cached_languages != []} class="pt-2">
            <button
              type="button"
              phx-click="remove_all_languages"
              aria-label="Remove all downloaded language packs"
              class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg border border-red-300 dark:border-red-700 text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors cursor-pointer"
            >
              <.icon name="hero-trash" class="size-3.5" /> Remove All
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign_tessdata_state()

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  # ── Tessdata management events ───────────────────────────────────────

  def handle_event("remove_language", %{"lang" => lang}, socket) do
    Quire.Ocr.Tessdata.remove(lang)
    {:noreply, assign_tessdata_state(socket)}
  end

  def handle_event("remove_all_languages", _params, socket) do
    cached = Quire.Ocr.Tessdata.cached_languages()

    Enum.each(cached, &Quire.Ocr.Tessdata.remove/1)

    socket =
      socket
      |> put_flash(:info, "All downloaded language packs have been removed.")
      |> assign_tessdata_state()

    {:noreply, socket}
  end

  # ── Tessdata helpers ─────────────────────────────────────────────────

  defp assign_tessdata_state(socket) do
    assign(socket,
      cached_languages: Quire.Ocr.Tessdata.cached_languages(),
      disk_usage: Quire.Ocr.Tessdata.disk_usage()
    )
  end

  defp language_label(lang) do
    Map.get(@known_languages, lang, lang)
  end

  defp format_bytes(n) when n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 2)} MB"
  defp format_bytes(n) when n >= 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_bytes(n), do: "#{n} B"
end
