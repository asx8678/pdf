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

      <!-- Form & Sign settings -->
      <div>
        <.header>
          Form &amp; Sign
          <:subtitle>Form field display and signature preferences</:subtitle>
        </.header>

        <div class="mt-4 space-y-4">
          <div class="flex items-center justify-between px-4 py-3 bg-gray-50 dark:bg-gray-800/50 rounded-lg">
            <div>
              <p class="text-sm font-medium text-gray-700 dark:text-gray-200">Highlight fields</p>
              <p class="text-xs text-gray-500 mt-1">Show a light-blue overlay on all form fields</p>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={@highlight_fields}
              aria-label="Highlight fields"
              phx-click="toggle_highlight_fields"
              class={[
                "relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2",
                if(@highlight_fields, do: "bg-indigo-600", else: "bg-gray-200 dark:bg-gray-700")
              ]}
            >
              <span aria-hidden="true" class={[
                "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                if(@highlight_fields, do: "translate-x-5", else: "translate-x-0")
              ]}></span>
            </button>
          </div>
        </div>
      </div>

      <hr class="my-8 border-chrome-border dark:border-gray-700" />

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

        <hr class="my-8 border-chrome-border dark:border-gray-700" />

        <!-- TOTP Two-Factor Authentication (T-163) -->
        <div>
          <.header>
            Two-Factor Authentication
            <:subtitle>Add an extra layer of security with a time-based one-time password</:subtitle>
          </.header>

          <div :if={!@totp_enabled} class="mt-4 space-y-4">
            <div class="p-4 bg-gray-50 dark:bg-gray-800/50 rounded-lg">
              <!-- Show generate button when no secret yet -->
              <div :if={is_nil(@totp_secret)} class="text-center">
                <p class="text-sm text-gray-600 dark:text-gray-400 mb-4">
                  Generate a secret key to set up two-factor authentication.
                </p>
                <.button type="button" phx-click="generate_totp_secret">
                  Generate Secret Key
                </.button>
              </div>

              <!-- Show secret + verify form after generation -->
              <div :if={!is_nil(@totp_secret)}>
                <p class="text-sm text-gray-600 dark:text-gray-400 mb-3">
                  Enter the secret below into your authenticator app (e.g. Google Authenticator, Authy).
                </p>

                <div class="text-center mb-4">
                  <p class="text-xs text-gray-500 mb-1">Secret key:</p>
                  <code class="text-sm font-mono bg-gray-100 dark:bg-gray-700 px-4 py-2 rounded-lg text-base tracking-widest select-all">
                    {@totp_secret}
                  </code>
                </div>

                <.form
                  for={@totp_form}
                  id="totp-enable-form"
                  phx-submit="enable_totp"
                  class="space-y-3"
                >
                  <.input
                    field={@totp_form[:code]}
                    type="text"
                    label="Enter the 6-digit code from your authenticator app"
                    placeholder="000000"
                    maxlength="6"
                    autocomplete="off"
                    required
                    class="text-center text-lg tracking-widest"
                  />
                  <div class="flex gap-2">
                    <.button type="submit" class="flex-1">
                      Enable Two-Factor Authentication
                    </.button>
                    <.button
                      type="button"
                      variant="outline"
                      phx-click="generate_totp_secret"
                    >
                      Regenerate
                    </.button>
                  </div>
                </.form>

                <p :if={@totp_error} class="mt-2 text-sm text-red-600 dark:text-red-400">
                  {@totp_error}
                </p>
              </div>
            </div>
          </div>

          <div :if={@totp_enabled} class="mt-4">
            <div class="flex items-center justify-between p-4 bg-gray-50 dark:bg-gray-800/50 rounded-lg">
              <div>
                <p class="text-sm font-medium text-gray-700 dark:text-gray-200">
                  Two-factor authentication is enabled
                </p>
                <p class="text-xs text-gray-500 mt-1">
                  Your account is protected with TOTP.
                </p>
              </div>
              <button
                type="button"
                phx-click="disable_totp"
                class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg border border-red-300 dark:border-red-700 text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors cursor-pointer"
              >
                <.icon name="hero-x-mark" class="size-3.5" /> Disable
              </button>
            </div>
          </div>
        </div>
      </div>

      <hr class="my-8 border-chrome-border dark:border-gray-700" />

      <!-- About — Engine version table -->
      <div>
        <.header>
          About
          <:subtitle>Component versions, engine status, and system information</:subtitle>
        </.header>

        <div :if={is_nil(@engine_check)} class="mt-4 text-sm text-gray-500 italic">
          Loading engine information…
        </div>

        <div :if={!is_nil(@engine_check)} class="mt-6 space-y-8">
          <!-- Engine status table -->
          <div>
            <h3 class="text-sm font-semibold text-gray-700 dark:text-gray-200 mb-3">Engines</h3>
            <div class="overflow-hidden rounded-lg border border-chrome-border dark:border-gray-700">
              <table class="min-w-full divide-y divide-chrome-border dark:divide-gray-700">
                <thead class="bg-gray-50 dark:bg-gray-800/50">
                  <tr>
                    <th class="px-4 py-2.5 text-left text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Engine</th>
                    <th class="px-4 py-2.5 text-left text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Status</th>
                    <th class="px-4 py-2.5 text-left text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Version</th>
                    <th class="px-4 py-2.5 text-left text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Detail</th>
                  </tr>
                </thead>
                <tbody class="bg-white dark:bg-gray-800/30 divide-y divide-chrome-border dark:divide-gray-700">
                  <tr :for={{mod, info} <- @engine_check.engines}>
                    <td class="px-4 py-2.5 text-sm text-gray-900 dark:text-gray-100 font-mono">
                      {engine_label(mod)}
                    </td>
                    <td class="px-4 py-2.5">
                      <%= case engine_state(info) do %>
                        <% :ok -> %>
                          <span class="inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-300">
                            <span class="w-1.5 h-1.5 rounded-full bg-green-500 inline-block"></span>
                            ok
                          </span>
                        <% :degraded -> %>
                          <span class="inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full bg-yellow-100 dark:bg-yellow-900/30 text-yellow-700 dark:text-yellow-300">
                            <span class="w-1.5 h-1.5 rounded-full bg-yellow-500 inline-block"></span>
                            degraded
                          </span>
                        <% :unavailable -> %>
                          <span class="inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-300">
                            <span class="w-1.5 h-1.5 rounded-full bg-red-500 inline-block"></span>
                            unavailable
                          </span>
                        <% _ -> %>
                          <span class="inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full bg-gray-100 dark:bg-gray-800 text-gray-500 dark:text-gray-400">
                            {engine_state(info)}
                          </span>
                      <% end %>
                    </td>
                    <td class="px-4 py-2.5 text-sm text-gray-600 dark:text-gray-400 font-mono">
                      {info[:version] || "—"}
                    </td>
                    <td class="px-4 py-2.5 text-sm text-gray-500 dark:text-gray-400">
                      {info[:detail] || ""}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <!-- System versions -->
          <div>
            <h3 class="text-sm font-semibold text-gray-700 dark:text-gray-200 mb-3">System</h3>
            <div class="grid grid-cols-2 gap-3">
              <div :for={{name, ver} <- @engine_check.system} class="flex items-center justify-between px-4 py-2.5 bg-gray-50 dark:bg-gray-800/30 rounded-lg">
                <span class="text-sm text-gray-600 dark:text-gray-400 capitalize">{Atom.to_string(name)}</span>
                <span class="text-sm font-mono text-gray-900 dark:text-gray-100">{ver || "—"}</span>
              </div>
            </div>
          </div>

          <!-- Smoke tests -->
          <div>
            <h3 class="text-sm font-semibold text-gray-700 dark:text-gray-200 mb-3">Smoke Tests</h3>
            <div class="space-y-2">
              <div :for={{name, result} <- @engine_check.smoke_tests} class="flex items-center justify-between px-4 py-2.5 bg-gray-50 dark:bg-gray-800/30 rounded-lg">
                <span class="text-sm text-gray-600 dark:text-gray-400 capitalize">{Atom.to_string(name) |> String.replace("_", " ")}</span>
                <span class={[
                  "text-sm font-medium",
                  if(result == :ok, do: "text-green-600 dark:text-green-400", else: "text-red-600 dark:text-red-400")
                ]}>
                  {if(result == :ok, do: "Pass", else: "Fail")}
                </span>
              </div>
            </div>
          </div>

          <!-- LGPL notice (libvips) -->
          <div class="px-4 py-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-700/40 rounded-lg">
            <p class="text-xs text-yellow-800 dark:text-yellow-200">
              This application uses libvips, which is licensed under the
              <a href="https://www.gnu.org/licenses/lgpl-3.0.html" target="_blank" rel="noopener" class="underline hover:no-underline">GNU Lesser General Public License v3.0 or later</a>.
            </p>
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
      |> assign_totp_state()
      |> assign(:highlight_fields,
        case Quire.Repo.get_by(Quire.Accounts.UserSetting, user_id: user.id) do
          nil -> false
          setting -> setting.highlight_fields
        end
      )
      |> assign(:engine_check, nil)

    self = self()
    Task.start(fn ->
      result = Quire.Engine.check()
      send(self, {:engine_check, result})
    end)

    {:ok, socket}
  end

  @impl true
  def handle_info({:engine_check, result}, socket) do
    {:noreply, assign(socket, :engine_check, result)}
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

  # ── TOTP events (T-163) ──────────────────────────────────────────────

  def handle_event("generate_totp_secret", _params, socket) do
    user = socket.assigns.current_scope.user

    {:ok, _secret, updated_user} = Accounts.generate_totp_secret(user)

    {:noreply,
     socket
     |> assign(:current_scope, %{socket.assigns.current_scope | user: updated_user})
     |> assign_totp_state()}
  end

  def handle_event("enable_totp", %{"user" => %{"code" => code}}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.enable_totp(user, code) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{socket.assigns.current_scope | user: user})
         |> assign_totp_state()
         |> put_flash(:info, "Two-factor authentication enabled.")}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, :totp_error, "Invalid code. Please try again.")}
    end
  end

  def handle_event("disable_totp", _params, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.disable_totp(user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{socket.assigns.current_scope | user: user})
         |> assign_totp_state()
         |> put_flash(:info, "Two-factor authentication disabled.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to disable two-factor authentication.")}
    end
  end

  # ── Form & Sign events (T-122) ──────────────────────────────────────

  def handle_event("toggle_highlight_fields", _params, socket) do
    user = socket.assigns.current_scope.user
    current = socket.assigns.highlight_fields
    new_value = !current

    # insert_all bypasses the schema, so pre-existing column drift
    # (schema-only :map fields without migration columns) won't break.
    Quire.Repo.insert_all(
      Quire.Accounts.UserSetting,
      [%{user_id: user.id, highlight_fields: new_value}],
      on_conflict: [set: [highlight_fields: new_value]],
      conflict_target: :user_id
    )

    {:noreply, assign(socket, :highlight_fields, new_value)}
  end

  # ── Tessdata helpers ─────────────────────────────────────────────────

  defp assign_tessdata_state(socket) do
    assign(socket,
      cached_languages: Quire.Ocr.Tessdata.cached_languages(),
      disk_usage: Quire.Ocr.Tessdata.disk_usage()
    )
  end

  defp assign_totp_state(socket) do
    user = socket.assigns.current_scope.user

    if user.totp_enabled do
      assign(socket,
        totp_enabled: true,
        totp_secret: nil,
        totp_form: nil,
        totp_error: nil
      )
    else
      secret_display =
        if user.totp_secret do
          Base.encode32(user.totp_secret, padding: false)
        else
          nil
        end

      totp_form = to_form(%{"code" => ""}, as: :user)

      assign(socket,
        totp_enabled: false,
        totp_secret: secret_display,
        totp_form: totp_form,
        totp_error: nil
      )
    end
  end

  defp language_label(lang) do
    Map.get(@known_languages, lang, lang)
  end

  defp format_bytes(n) when n >= 1_048_576, do: "\#{Float.round(n / 1_048_576, 2)} MB"
  defp format_bytes(n) when n >= 1024, do: "\#{Float.round(n / 1024, 1)} KB"
  defp format_bytes(n), do: "\#{n} B"

  # ── Engine version table helpers (T-166) ──────────────────────────────

  @engine_labels %{
    Quire.Render => "Rasterisation & Text Extraction",
    Quire.Ocr.Engine => "OCR / Image-to-Text",
    Quire.Office.Writer => "Office Document Writing",
    Quire.Pades => "PAdES Signing / Validation",
    Quire.SecurityHandler => "Document Encryption",
    Quire.PdfA => "PDF/A Conversion",
    Quire.Compose => "Content-Stream Composition",
    ChromicPDF => "HTML/URL to PDF (ChromicPDF)",
    Quire.Pdf => "PDF Object Model (lopdf NIF)",
    Quire.Render.Pdfium => "Rendering Engine (PDFium)",
    Quire.Ocr.Tesseract => "OCR Engine (Tesseract)",
    Quire.Ocr.Preprocess => "OCR Preprocessing (vips)"
  }

  defp engine_label(mod) do
    Map.get(@engine_labels, mod, mod |> Atom.to_string() |> String.replace_prefix("Elixir.", ""))
  end

  defp engine_state(info) do
    info[:state] || :unavailable
  end
end
