defmodule QuireWeb.Chrome.EsignWizard do
  @moduledoc """
  Request-signature wizard overlay (plan3.md §9.9, T-147).

  A multi-step wizard for creating and sending signature envelopes:
    1. Signers — add/remove signers (name, email, order, role)
    2. Fields — place signature fields per signer
    3. Compose — subject and message
    4. Expiry — set deadline and reminders
    5. Send — review and send

  Rendered as an overlay within workspace_live, keeping the PDF viewer
  accessible underneath for field placement.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]
  import QuireWeb.Shared.Modal, only: [modal: 1]

  @steps [:signers, :fields, :compose, :expiry, :send]

  attr :open, :boolean, default: false
  attr :step, :atom, default: :signers
  attr :signers, :list, default: []
  attr :fields, :list, default: []
  attr :subject, :string, default: ""
  attr :message, :string, default: ""
  attr :expires_at, :any, default: nil
  attr :sending, :boolean, default: false
  attr :error, :string, default: nil

  def esign_wizard(assigns) do
    ~H"""
    <.modal title={wizard_title(@step)} open={@open} on_close="close_esign_wizard" size="large">
      <div class="min-h-[400px]">
        <!-- Step indicator -->
        <div class="flex items-center justify-center gap-4 mb-6">
          <div :for={s <- @steps} class="flex items-center gap-2">
            <div class={[
              "w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold transition-colors",
              step_completed?(@step, s) && "bg-accent text-white",
              @step == s &&
                "ring-2 ring-accent ring-offset-2 dark:ring-offset-gray-800 bg-accent text-white",
              !step_completed?(@step, s) && @step != s && "bg-gray-200 dark:bg-gray-700 text-gray-500"
            ]}>
              {step_number(s)}
            </div>
            <span class={[
              "text-xs font-medium",
              if(@step == s, do: "text-gray-900 dark:text-gray-100", else: "text-gray-400")
            ]}>
              {step_label(s)}
            </span>
          </div>
        </div>

        <!-- Step content -->
        <div class="space-y-4">
          <%= case @step do %>
            <% :signers -> %>
              <.signers_step :if={@step == :signers} signers={@signers} />
            <% :fields -> %>
              <.fields_step signers={@signers} fields={@fields} />
            <% :compose -> %>
              <.compose_step subject={@subject} message={@message} />
            <% :expiry -> %>
              <.expiry_step expires_at={@expires_at} />
            <% :send -> %>
              <.send_step
                signers={@signers}
                fields={@fields}
                subject={@subject}
                message={@message}
                expires_at={@expires_at}
                sending={@sending}
                error={@error}
              />
          <% end %>
        </div>
      </div>

      <!-- Footer navigation -->
      <div class="flex justify-between items-center pt-4 mt-4 border-t border-chrome-border dark:border-gray-600">
        <div>
          <button
            :if={@step != :signers}
            type="button"
            phx-click="esign_wizard_prev"
            class="px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
          >
            Back
          </button>
        </div>
        <div class="flex gap-2">
          <button
            type="button"
            phx-click="close_esign_wizard"
            class="px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
          >
            Cancel
          </button>
          <%= if @step == :send do %>
            <button
              type="button"
              phx-click="esign_wizard_send"
              disabled={@sending}
              class={[
                "px-4 py-2 text-sm font-medium rounded-lg transition-colors",
                if(@sending,
                  do: "bg-gray-400 text-white cursor-not-allowed",
                  else: "bg-accent text-white hover:bg-accent/90"
                )
              ]}
            >
              {if @sending, do: "Sending...", else: "Send for Signature"}
            </button>
          <% else %>
            <button
              type="button"
              phx-click="esign_wizard_next"
              disabled={next_disabled?(@step, @signers)}
              class={[
                "px-4 py-2 text-sm font-medium rounded-lg transition-colors",
                if(next_disabled?(@step, @signers),
                  do: "bg-gray-300 dark:bg-gray-600 text-gray-500 cursor-not-allowed",
                  else: "bg-accent text-white hover:bg-accent/90"
                )
              ]}
            >
              Next
            </button>
          <% end %>
        </div>
      </div>
    </.modal>
    """
  end

  defp wizard_title(:signers), do: "Request Signature — Signers"
  defp wizard_title(:fields), do: "Request Signature — Place Fields"
  defp wizard_title(:compose), do: "Request Signature — Compose"
  defp wizard_title(:expiry), do: "Request Signature — Expiry & Reminders"
  defp wizard_title(:send), do: "Request Signature — Review & Send"

  defp step_number(step), do: Enum.find_index(@steps, &(&1 == step)) + 1
  defp step_label(:signers), do: "Signers"
  defp step_label(:fields), do: "Fields"
  defp step_label(:compose), do: "Compose"
  defp step_label(:expiry), do: "Expiry"
  defp step_label(:send), do: "Send"

  defp step_completed?(current, step) do
    Enum.find_index(@steps, &(&1 == step)) < Enum.find_index(@steps, &(&1 == current))
  end

  defp next_disabled?(:signers, signers), do: length(signers) == 0
  defp next_disabled?(_, _), do: false

  ## ── Step 1: Signers ──────────────────────────────────────────────────────

  attr :signers, :list, default: []

  defp signers_step(assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-gray-600 dark:text-gray-400">
        Add the people who need to sign this document. Signers will receive an email notification.
      </p>

      <!-- Signer list -->
      <div class="space-y-2">
        <div
          :for={s <- @signers}
          class="flex items-center gap-3 p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg"
        >
          <div class="flex-1 grid grid-cols-3 gap-2">
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Name</label>
              <input
                type="text"
                name="name"
                value={s.name}
                phx-change="esign_wizard_update_signer"
                phx-value-index={s.order - 1}
                phx-value-field="name"
                placeholder="Full name"
                class="w-full px-2 py-1.5 text-sm border border-chrome-border dark:border-gray-600 rounded-lg bg-chrome-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-accent focus:border-accent outline-none"
              />
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Email</label>
              <input
                type="email"
                name="email"
                value={s.email}
                phx-change="esign_wizard_update_signer"
                phx-value-index={s.order - 1}
                phx-value-field="email"
                placeholder="email@example.com"
                class="w-full px-2 py-1.5 text-sm border border-chrome-border dark:border-gray-600 rounded-lg bg-chrome-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-accent focus:border-accent outline-none"
              />
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Role (optional)</label>
              <input
                type="text"
                name="role"
                value={s.role}
                phx-change="esign_wizard_update_signer"
                phx-value-index={s.order - 1}
                phx-value-field="role"
                placeholder="e.g. Manager"
                class="w-full px-2 py-1.5 text-sm border border-chrome-border dark:border-gray-600 rounded-lg bg-chrome-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-accent focus:border-accent outline-none"
              />
            </div>
          </div>
          <button
            type="button"
            phx-click="esign_wizard_remove_signer"
            phx-value-index={s.order - 1}
            class="p-1.5 text-gray-400 hover:text-red-500 rounded-lg hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors"
            aria-label={"Remove #{s.name}"}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <!-- Empty state -->
        <div :if={length(@signers) == 0} class="text-center py-8 text-gray-400">
          <.icon name="hero-user-plus" class="size-10 mx-auto mb-2" />
          <p class="text-sm">No signers added yet</p>
        </div>
      </div>

      <!-- Add signer button -->
      <button
        type="button"
        phx-click="esign_wizard_add_signer"
        class="flex items-center gap-2 px-3 py-2 text-sm font-medium text-accent hover:bg-accent/5 rounded-lg transition-colors"
      >
        <.icon name="hero-plus" class="size-4" /> Add Signer
      </button>
    </div>
    """
  end

  ## ── Step 2: Fields ───────────────────────────────────────────────────────

  attr :signers, :list, default: []
  attr :fields, :list, default: []

  defp fields_step(assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-gray-600 dark:text-gray-400">
        Place signature fields on the document. Each field is colour-coded by signer.
        Select a signer, then add fields where they need to sign.
      </p>

      <div
        :for={s <- @signers}
        class="border border-chrome-border dark:border-gray-600 rounded-lg p-3"
      >
        <div class="flex items-center gap-2 mb-2">
          <div
            class="w-3 h-3 rounded-full"
            style={"background-color: #{signer_color(s.order)}"}
          />
          <span class="text-sm font-medium text-gray-900 dark:text-gray-100">{s.name}</span>
          <span class="text-xs text-gray-400">{s.email}</span>
        </div>

        <!-- Fields for this signer -->
        <div class="ml-5 space-y-1">
          <div
            :for={f <- Enum.filter(@fields, &(&1.signer_index == s.order - 1))}
            class="flex items-center gap-2 p-2 bg-gray-50 dark:bg-gray-700/50 rounded text-sm"
          >
            <.icon name={field_icon(f.kind)} class="size-3.5 text-gray-500" />
            <span class="text-gray-700 dark:text-gray-300">{field_label(f.kind)}</span>
            <span class="text-xs text-gray-400">Page {f.page_index + 1}</span>

            <!-- Field kind selector -->
            <select
              name="kind"
              phx-change="esign_wizard_update_field"
              phx-value-id={f.id}
              phx-value-field="kind"
              class="ml-2 px-2 py-0.5 text-xs border border-chrome-border dark:border-gray-600 rounded bg-chrome-white dark:bg-gray-700 text-gray-700 dark:text-gray-300"
            >
              <option
                :for={kt <- ~w(signature initials name date text checkbox)}
                value={kt}
                selected={Atom.to_string(f.kind) == kt}
              >
                {field_label(String.to_existing_atom(kt))}
              </option>
            </select>

            <button
              type="button"
              phx-click="esign_wizard_remove_field"
              phx-value-id={f.id}
              class="ml-auto p-0.5 text-gray-400 hover:text-red-500"
              aria-label={"Remove #{field_label(f.kind)}"}
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </div>
          <p
            :if={length(Enum.filter(@fields, &(&1.signer_index == s.order - 1))) == 0}
            class="text-xs text-gray-400 italic"
          >
            No fields placed
          </p>
        </div>

        <button
          type="button"
          phx-click="esign_wizard_add_field"
          phx-value-signer_index={s.order - 1}
          class="ml-5 mt-1 flex items-center gap-1 text-xs text-accent hover:text-accent/80"
        >
          <.icon name="hero-plus-circle" class="size-3.5" /> Add field
        </button>
      </div>

      <div :if={length(@signers) == 0} class="text-center py-8 text-gray-400">
        <p class="text-sm">Add signers first to place fields</p>
      </div>
    </div>
    """
  end

  ## ── Step 3: Compose ──────────────────────────────────────────────────────

  attr :subject, :string, default: ""
  attr :message, :string, default: ""

  defp compose_step(assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-gray-600 dark:text-gray-400">
        Compose the email that will be sent to signers.
      </p>

      <div>
        <label
          for="esign-subject"
          class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
        >
          Subject
        </label>
        <input
          id="esign-subject"
          type="text"
          name="subject"
          value={@subject}
          phx-change="esign_wizard_update_compose"
          phx-value-field="subject"
          placeholder="Please sign this document"
          class="w-full px-3 py-2 border border-chrome-border dark:border-gray-600 rounded-lg text-sm bg-chrome-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-accent focus:border-accent outline-none"
        />
      </div>

      <div>
        <label
          for="esign-message"
          class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
        >
          Message
        </label>
        <textarea
          id="esign-message"
          name="message"
          rows="4"
          phx-change="esign_wizard_update_compose"
          phx-value-field="message"
          placeholder="Add a personal message..."
          class="w-full px-3 py-2 border border-chrome-border dark:border-gray-600 rounded-lg text-sm bg-chrome-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-accent focus:border-accent outline-none resize-none"
        ><%= @message %></textarea>
      </div>
    </div>
    """
  end

  ## ── Step 4: Expiry ───────────────────────────────────────────────────────

  attr :expires_at, :any, default: nil

  defp expiry_step(assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-gray-600 dark:text-gray-400">
        Set a deadline for signing. Signers who haven't signed by this date will
        receive reminder emails.
      </p>

      <div>
        <label
          for="esign-expires"
          class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
        >
          Expires at
        </label>
        <input
          id="esign-expires"
          type="datetime-local"
          name="expires_at"
          value={format_datetime_local(@expires_at)}
          phx-change="esign_wizard_update_expiry"
          class="w-full px-3 py-2 border border-chrome-border dark:border-gray-600 rounded-lg text-sm bg-chrome-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-accent focus:border-accent outline-none"
        />
      </div>

      <p class="text-xs text-gray-400">
        Leave empty for no expiry. Reminders are sent 7 days, 3 days, and 1 day before expiry.
      </p>
    </div>
    """
  end

  ## ── Step 5: Review & Send ────────────────────────────────────────────────

  attr :signers, :list, default: []
  attr :fields, :list, default: []
  attr :subject, :string, default: ""
  attr :message, :string, default: ""
  attr :expires_at, :any, default: nil
  attr :sending, :boolean, default: false
  attr :error, :string, default: nil

  defp send_step(assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-gray-600 dark:text-gray-400">
        Review your signature request before sending.
      </p>

      <!-- Error -->
      <div
        :if={@error}
        class="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg text-sm text-red-700 dark:text-red-400"
      >
        {@error}
      </div>

      <!-- Summary -->
      <div class="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-4 space-y-3">
        <div>
          <h4 class="text-xs font-semibold text-gray-500 uppercase tracking-wider">Signers</h4>
          <ul class="mt-1 space-y-1">
            <li
              :for={s <- @signers}
              class="text-sm text-gray-700 dark:text-gray-300 flex items-center gap-2"
            >
              <span class="w-2 h-2 rounded-full" style={"background-color: #{signer_color(s.order)}"} />
              {s.name} <span class="text-xs text-gray-400">({s.email})</span>
            </li>
          </ul>
        </div>

        <div :if={length(@fields) > 0}>
          <h4 class="text-xs font-semibold text-gray-500 uppercase tracking-wider">Fields</h4>
          <p class="mt-1 text-sm text-gray-600 dark:text-gray-400">
            {length(@fields)} field(s) placed
          </p>
        </div>

        <div>
          <h4 class="text-xs font-semibold text-gray-500 uppercase tracking-wider">Subject</h4>
          <p class="mt-1 text-sm text-gray-700 dark:text-gray-300">{@subject}</p>
        </div>

        <div :if={@message != ""}>
          <h4 class="text-xs font-semibold text-gray-500 uppercase tracking-wider">Message</h4>
          <p class="mt-1 text-sm text-gray-600 dark:text-gray-400">{@message}</p>
        </div>

        <div :if={@expires_at}>
          <h4 class="text-xs font-semibold text-gray-500 uppercase tracking-wider">Expires</h4>
          <p class="mt-1 text-sm text-gray-600 dark:text-gray-400">{format_datetime(@expires_at)}</p>
        </div>
      </div>
    </div>
    """
  end

  ## ── Helpers ──────────────────────────────────────────────────────────────

  @field_types [:signature, :initials, :name, :date, :text, :checkbox]

  defp signer_color(order) when is_integer(order) do
    colors = ["#4F46E5", "#059669", "#D97706", "#DC2626", "#7C3AED", "#0891B2"]
    Enum.at(colors, rem(order - 1, length(colors)))
  end

  defp field_icon(:signature), do: "hero-pencil"
  defp field_icon(:initials), do: "hero-at-symbol"
  defp field_icon(:name), do: "hero-user"
  defp field_icon(:date), do: "hero-calendar"
  defp field_icon(:text), do: "hero-document-text"
  defp field_icon(:checkbox), do: "hero-check"

  defp field_label(:signature), do: "Signature"
  defp field_label(:initials), do: "Initials"
  defp field_label(:name), do: "Full Name"
  defp field_label(:date), do: "Date"
  defp field_label(:text), do: "Text"
  defp field_label(:checkbox), do: "Checkbox"

  defp format_datetime_local(nil), do: ""

  defp format_datetime_local(%DateTime{} = dt) do
    dt |> DateTime.to_naive() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(%DateTime{} = dt) do
    dt |> DateTime.to_naive() |> NaiveDateTime.to_string()
  end
end
