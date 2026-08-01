defmodule QuireWeb.Chrome.DigitalSignaturePanel do
  @moduledoc """
  Digital signature panel (plan3.md §9.7, T-130): a right-side panel for
  the PAdES digital signature flow.

  ## Flow

    1. Select or upload a certificate (PKCS#12 keystore)
    2. Choose PAdES level: B-B (basic) or B-T (with RFC 3161 timestamp)
    3. Place the visible signature field on the document (drag rect)
    4. Optionally enter reason, location, contact info
    5. Sign — triggers server-side signing via `SignWorker`

  The signed document is stored and a `digital_signatures` row is created.
  """

  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  attr :certificates, :list, default: []
  attr :selected_cert_index, :integer, default: nil
  attr :pades_level, :string, default: "b_b"
  attr :field_rect, :list, default: nil
  attr :field_name, :string, default: ""
  attr :reason, :string, default: ""
  attr :location, :string, default: ""
  attr :contact_info, :string, default: ""
  attr :signing, :boolean, default: false
  attr :signed, :boolean, default: false
  attr :error, :string, default: nil
  attr :signing_mode, :boolean, default: false
  attr :signing_result, :any, default: nil

  def digital_signature_panel(assigns) do
    ~H"""
    <div
      id="digital-signature-panel"
      class="flex-1 flex flex-col min-h-0"
    >
      <div class="px-4 py-3 border-b border-chrome-border dark:border-gray-600">
        <h3 class="text-sm font-semibold text-gray-800 dark:text-gray-200">
          Digital Signature (PAdES)
        </h3>
        <p class="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
          Cryptographically sign this PDF with a certificate
        </p>
      </div>

      <div class="flex-1 overflow-y-auto p-4 space-y-5">
        <%= if @signed do %>
          <%!-- Signed confirmation --%>
          <div class="bg-green-50 dark:bg-green-900/30 border border-green-200 dark:border-green-800 rounded-xl p-4 text-center">
            <.icon name="hero-check-circle" class="size-8 text-green-500 mx-auto mb-2" />
            <p class="text-sm font-medium text-green-700 dark:text-green-300">
              Document Signed
            </p>
            <p class="text-xs text-green-600 dark:text-green-400 mt-1">
              A PAdES {@pades_level |> String.upcase()} digital signature
              has been applied to this document.
            </p>
            <%= if @signing_result do %>
              <p class="text-xs text-green-500 dark:text-green-300 mt-1 font-mono truncate">
                Sig: {Map.get(@signing_result, :signature_hex, "") |> String.slice(0, 16)}...
              </p>
            <% end %>
          </div>
        <% else %>
          <%!-- Certificate selection --%>
          <div>
            <label class="block text-xs font-medium text-gray-600 dark:text-gray-400 uppercase tracking-wider mb-2">
              Certificate
            </label>

            <%= if @certificates == [] do %>
              <div class="border-2 border-dashed border-gray-300 dark:border-gray-600 rounded-xl p-4 text-center">
                <.icon
                  name="hero-shield-exclamation"
                  class="size-6 text-gray-300 dark:text-gray-500 mx-auto mb-2"
                />
                <p class="text-xs text-gray-500 dark:text-gray-400">
                  No certificates available.
                </p>
                <button
                  type="button"
                  phx-click="open_certificate_manager"
                  class="mt-2 px-3 py-1.5 text-xs font-medium rounded-lg bg-accent text-white hover:bg-accent/90 transition-colors cursor-pointer"
                >
                  Upload Certificate
                </button>
              </div>
            <% else %>
              <div class="space-y-2">
                <div
                  :for={{idx, cert} <- Enum.with_index(@certificates)}
                  id={"ds-cert-#{idx}"}
                  phx-click="select_ds_cert"
                  phx-value-index={idx}
                  class={[
                    "p-3 rounded-lg border-2 transition-all cursor-pointer",
                    @selected_cert_index == idx &&
                      "border-accent bg-accent/5 dark:bg-accent/10",
                    @selected_cert_index != idx &&
                      "border-gray-200 dark:border-gray-700 hover:border-accent/50"
                  ]}
                >
                  <div class="flex items-center gap-2">
                    <div class={[
                      "w-4 h-4 rounded-full border-2 flex items-center justify-center shrink-0",
                      @selected_cert_index == idx && "border-accent",
                      @selected_cert_index != idx && "border-gray-300 dark:border-gray-600"
                    ]}>
                      <div
                        :if={@selected_cert_index == idx}
                        class="w-2 h-2 rounded-full bg-accent"
                      />
                    </div>
                    <div class="min-w-0">
                      <p class="text-xs font-medium text-gray-700 dark:text-gray-200 truncate">
                        {cert.subject_cn || "Unknown"}
                      </p>
                      <p class="text-[10px] text-gray-400 dark:text-gray-500 truncate">
                        {cert.algorithm |> to_string() |> String.upcase()}
                      </p>
                    </div>
                  </div>
                </div>

                <button
                  type="button"
                  phx-click="open_certificate_manager"
                  class="w-full px-3 py-1.5 text-xs font-medium rounded-lg border border-gray-200 dark:border-gray-600 text-gray-600 dark:text-gray-400 hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors cursor-pointer"
                >
                  + Add Certificate
                </button>
              </div>
            <% end %>
          </div>

          <%!-- PAdES level --%>
          <div>
            <label class="block text-xs font-medium text-gray-600 dark:text-gray-400 uppercase tracking-wider mb-2">
              PAdES Level
            </label>
            <div class="grid grid-cols-2 gap-2">
              <button
                type="button"
                phx-click="select_ds_level"
                phx-value-level="b_b"
                class={[
                  "p-3 rounded-lg border-2 text-left transition-all cursor-pointer",
                  @pades_level == "b_b" &&
                    "border-accent bg-accent/5 dark:bg-accent/10",
                  @pades_level != "b_b" &&
                    "border-gray-200 dark:border-gray-700 hover:border-accent/50"
                ]}
              >
                <p class="text-xs font-semibold text-gray-800 dark:text-gray-200">
                  B-B (Basic)
                </p>
                <p class="text-[10px] text-gray-500 dark:text-gray-400 mt-1">
                  CMS detached signature with signed attributes
                </p>
              </button>

              <button
                type="button"
                phx-click="select_ds_level"
                phx-value-level="b_t"
                class={[
                  "p-3 rounded-lg border-2 text-left transition-all cursor-pointer",
                  @pades_level == "b_t" &&
                    "border-accent bg-accent/5 dark:bg-accent/10",
                  @pades_level != "b_t" &&
                    "border-gray-200 dark:border-gray-700 hover:border-accent/50"
                ]}
              >
                <p class="text-xs font-semibold text-gray-800 dark:text-gray-200">
                  B-T (Timestamp)
                </p>
                <p class="text-[10px] text-gray-500 dark:text-gray-400 mt-1">
                  B-B + RFC 3161 timestamp token
                </p>
              </button>
            </div>
          </div>

          <%!-- Field placement --%>
          <div>
            <label class="block text-xs font-medium text-gray-600 dark:text-gray-400 uppercase tracking-wider mb-2">
              Signature Field
            </label>

            <%= if @field_rect do %>
              <div class="p-3 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg">
                <p class="text-xs text-blue-700 dark:text-blue-300">
                  Field placed: [{Enum.join(@field_rect, ", ")}]
                </p>
                <button
                  type="button"
                  phx-click="clear_ds_field"
                  class="mt-2 text-xs text-blue-600 dark:text-blue-400 underline cursor-pointer"
                >
                  Clear &amp; re-place
                </button>
              </div>
            <% else %>
              <div class="border-2 border-dashed border-gray-300 dark:border-gray-600 rounded-xl p-4 text-center">
                <.icon
                  name="hero-cursor-arrow-rays"
                  class="size-6 text-gray-300 dark:text-gray-500 mx-auto mb-2"
                />
                <p class="text-xs text-gray-500 dark:text-gray-400">
                  Click "Place Field" then drag on the document
                </p>
                <button
                  type="button"
                  phx-click="start_ds_field_placement"
                  class="mt-2 px-3 py-1.5 text-xs font-medium rounded-lg bg-accent text-white hover:bg-accent/90 transition-colors cursor-pointer"
                >
                  Place Field
                </button>
              </div>
            <% end %>
          </div>

          <%!-- Sign button --%>
          <button
            type="button"
            id="ds-sign-button"
            phx-click="perform_digital_signature"
            disabled={@selected_cert_index == nil || @field_rect == nil || @signing}
            class={[
              "w-full px-4 py-3 text-sm font-semibold rounded-xl transition-all flex items-center justify-center gap-2",
              @selected_cert_index != nil && @field_rect != nil && !@signing &&
                "bg-accent text-white hover:bg-accent/90 cursor-pointer shadow-lg shadow-accent/25",
              (@selected_cert_index == nil || @field_rect == nil || @signing) &&
                "bg-gray-200 dark:bg-gray-700 text-gray-400 dark:text-gray-500 cursor-not-allowed"
            ]}
          >
            <%= if @signing do %>
              <svg
                class="animate-spin size-4"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
              >
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                >
                </circle>
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                >
                </path>
              </svg>
              Signing...
            <% else %>
              <.icon name="hero-lock-closed" class="size-4" /> Apply PAdES Signature
            <% end %>
          </button>

          <%= if @error do %>
            <div class="p-3 bg-red-50 dark:bg-red-900/30 border border-red-200 dark:border-red-800 rounded-lg">
              <p class="text-xs text-red-700 dark:text-red-300 flex items-center gap-1">
                <.icon name="hero-exclamation-triangle" class="size-3" />
                {@error}
              </p>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end
end
