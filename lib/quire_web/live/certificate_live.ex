defmodule QuireWeb.CertificateLive do
  @moduledoc """
  Certificate management LiveView for the PAdES signing flow (§9.7, T-130).

  Allows users to:
    - Upload a PKCS#12 (.p12 / .pfx) keystore
    - View the parsed certificate information (subject, issuer, validity,
      key algorithm, serial number)
    - Select a certificate for signing
    - Manage saved certificates for reuse

  Part of the flow: choose/upload certificate → place visible field →
  sign → validate → store digital_signatures row.
  """

  use QuireWeb, :live_view

  alias Quire.Pades

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Certificate Management")
      |> assign(:step, :choose)
      |> assign(:certificates, [])
      |> assign(:current_cert, nil)
      |> assign(:password, "")
      |> assign(:errors, [])
      |> assign(:uploading, false)
      |> assign(:selected_cert_index, nil)
      |> assign(:cert_info, nil)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-4xl mx-auto px-4 py-8">
        <div class="mb-8">
          <h1 class="text-2xl font-bold text-gray-900 dark:text-gray-100">
            Digital Signature Certificate
          </h1>
          <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
            Choose or upload a certificate to use for PAdES digital signatures.
          </p>
        </div>

        <%= if @errors != [] do %>
          <div class="mb-6 bg-red-50 dark:bg-red-900/30 border border-red-200 dark:border-red-800 rounded-xl p-4">
            <div :for={error <- @errors} class="text-sm text-red-700 dark:text-red-300">
              <.icon name="hero-exclamation-triangle" class="size-4 inline mr-1" /> {error}
            </div>
          </div>
        <% end %>

        <%!-- Saved certificates list --%>
        <div :if={@certificates != []} class="mb-8">
          <h2 class="text-lg font-semibold text-gray-800 dark:text-gray-200 mb-3">
            Saved Certificates
          </h2>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
            <div
              :for={{idx, cert} <- Enum.with_index(@certificates)}
              id={"cert-card-#{idx}"}
              phx-click="select_cert"
              phx-value-index={idx}
              class={[
                "p-4 rounded-xl border-2 transition-all cursor-pointer",
                @selected_cert_index == idx &&
                  "border-accent bg-accent/5 dark:bg-accent/10",
                @selected_cert_index != idx &&
                  "border-gray-200 dark:border-gray-700 hover:border-accent/50 hover:bg-gray-50 dark:hover:bg-gray-800"
              ]}
            >
              <div class="flex items-start gap-3">
                <div class="w-10 h-10 rounded-lg bg-gradient-to-br from-blue-500 to-purple-600 flex items-center justify-center shrink-0">
                  <.icon name="hero-shield-check" class="size-5 text-white" />
                </div>
                <div class="flex-1 min-w-0">
                  <p class="font-medium text-sm text-gray-900 dark:text-gray-100 truncate">
                    {cert.subject_cn || "Unknown Certificate"}
                  </p>
                  <p class="text-xs text-gray-500 dark:text-gray-400 truncate">
                    Issued by: {cert.issuer_cn || "Unknown CA"}
                  </p>
                  <p class="text-xs text-gray-400 dark:text-gray-500 mt-1">
                    {cert.algorithm |> to_string() |> String.upcase()} •
                    Expires {format_date(cert.valid_to)}
                  </p>
                </div>
                <div class="shrink-0">
                  <div class={[
                    "w-5 h-5 rounded-full border-2 flex items-center justify-center",
                    @selected_cert_index == idx && "border-accent bg-accent",
                    @selected_cert_index != idx && "border-gray-300 dark:border-gray-600"
                  ]}>
                    <div
                      :if={@selected_cert_index == idx}
                      class="w-2 h-2 rounded-full bg-white"
                    />
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Upload a new certificate --%>
        <div class="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-6">
          <h2 class="text-lg font-semibold text-gray-800 dark:text-gray-200 mb-4">
            Upload PKCS#12 Keystore
          </h2>
          <p class="text-sm text-gray-500 dark:text-gray-400 mb-4">
            Upload a .p12 or .pfx file containing your signing certificate
            and private key. You will need the keystore password to decrypt it.
          </p>

          <.form
            for={to_form(%{}, as: :cert_upload)}
            id="cert-upload-form"
            phx-submit="upload_cert"
            phx-change="validate_cert_upload"
          >
            <div class="space-y-4">
              <%!-- File upload zone --%>
              <div
                id="cert-upload-zone"
                phx-hook=".CertUpload"
                class="border-2 border-dashed border-gray-300 dark:border-gray-600 rounded-xl p-8 text-center transition-colors hover:border-accent/50"
              >
                <.icon
                  name="hero-document-arrow-up"
                  class="size-10 text-gray-300 dark:text-gray-500 mx-auto mb-3"
                />
                <p class="text-sm text-gray-500 dark:text-gray-400">
                  Drag and drop a .p12 / .pfx file, or click to browse
                </p>
                <p class="text-xs text-gray-400 dark:text-gray-500 mt-1">
                  Maximum file size: 10 MB
                </p>
                <input
                  type="file"
                  id="cert-file-input"
                  name="cert_upload[file]"
                  accept=".p12,.pfx,application/x-pkcs12"
                  class="hidden"
                />
              </div>

              <%!-- Selected file indicator --%>
              <div
                :if={@uploading}
                id="cert-file-selected"
                class="flex items-center gap-3 px-4 py-3 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg"
              >
                <.icon name="hero-document-check" class="size-5 text-green-600" />
                <div>
                  <p class="text-sm font-medium text-green-700 dark:text-green-300">
                    File selected
                  </p>
                  <p class="text-xs text-green-600 dark:text-green-400">
                    Ready to upload — enter the password below
                  </p>
                </div>
              </div>

              <%!-- Password --%>
              <div>
                <label
                  for="cert-password"
                  class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
                >
                  Keystore Password
                </label>
                <input
                  type="password"
                  id="cert-password"
                  name="cert_upload[password]"
                  value={@password}
                  placeholder="Enter the keystore password"
                  class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-900 text-gray-900 dark:text-gray-100 text-sm focus:ring-1 focus:ring-accent focus:border-accent placeholder-gray-400"
                />
              </div>

              <%!-- Upload button --%>
              <div class="flex justify-end">
                <button
                  type="submit"
                  id="cert-upload-submit"
                  disabled={!@uploading || @password == ""}
                  class={[
                    "px-6 py-2.5 text-sm font-medium rounded-lg transition-all",
                    @uploading && @password != "" &&
                      "bg-accent text-white hover:bg-accent/90 cursor-pointer",
                    (!@uploading || @password == "") &&
                      "bg-gray-200 dark:bg-gray-700 text-gray-400 dark:text-gray-500 cursor-not-allowed"
                  ]}
                >
                  Upload &amp; Parse
                </button>
              </div>
            </div>
          </.form>
        </div>

        <%!-- Certificate info panel --%>
        <div
          :if={@cert_info}
          id="cert-info-panel"
          class="mt-6 bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-6"
        >
          <h2 class="text-lg font-semibold text-gray-800 dark:text-gray-200 mb-4 flex items-center gap-2">
            <.icon name="hero-check-circle" class="size-5 text-green-500" />
            Certificate Parsed Successfully
          </h2>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div class="space-y-3">
              <div>
                <p class="text-xs text-gray-400 dark:text-gray-500 uppercase tracking-wider">
                  Subject
                </p>
                <p class="text-sm font-medium text-gray-900 dark:text-gray-100">
                  {@cert_info.subject_cn || "N/A"}
                </p>
              </div>
              <div>
                <p class="text-xs text-gray-400 dark:text-gray-500 uppercase tracking-wider">
                  Issuer
                </p>
                <p class="text-sm font-medium text-gray-900 dark:text-gray-100">
                  {@cert_info.issuer_cn || "N/A"}
                </p>
              </div>
              <div>
                <p class="text-xs text-gray-400 dark:text-gray-500 uppercase tracking-wider">
                  Serial Number
                </p>
                <p class="text-sm font-mono text-gray-700 dark:text-gray-300 truncate">
                  {@cert_info.serial || "N/A"}
                </p>
              </div>
            </div>

            <div class="space-y-3">
              <div>
                <p class="text-xs text-gray-400 dark:text-gray-500 uppercase tracking-wider">
                  Key Algorithm
                </p>
                <p class="text-sm font-medium text-gray-900 dark:text-gray-100">
                  {(@cert_info.algorithm || :rsa) |> to_string() |> String.upcase()}
                </p>
              </div>
              <div>
                <p class="text-xs text-gray-400 dark:text-gray-500 uppercase tracking-wider">
                  Valid From
                </p>
                <p class="text-sm text-gray-700 dark:text-gray-300">
                  {format_date(@cert_info.valid_from)}
                </p>
              </div>
              <div>
                <p class="text-xs text-gray-400 dark:text-gray-500 uppercase tracking-wider">
                  Valid To
                </p>
                <p class={[
                  "text-sm font-medium",
                  cert_expiring_soon?(@cert_info.valid_to) &&
                    "text-amber-600 dark:text-amber-400",
                  !cert_expiring_soon?(@cert_info.valid_to) &&
                    "text-gray-700 dark:text-gray-300"
                ]}>
                  {format_date(@cert_info.valid_to)}
                  <span
                    :if={cert_expired?(@cert_info.valid_to)}
                    class="ml-2 text-xs text-red-500 font-bold"
                  >
                    EXPIRED
                  </span>
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CertUpload">
        export default {
          mounted() {
            this._input = document.getElementById("cert-file-input");
            this._zone = document.getElementById("cert-upload-zone");

            if (!this._input || !this._zone) return;

            // Click to browse
            this._zone.addEventListener("click", (e) => {
              if (e.target.tagName !== "INPUT") {
                this._input.click();
              }
            });

            // Drag and drop
            this._zone.addEventListener("dragover", (e) => {
              e.preventDefault();
              this._zone.classList.add("border-accent", "bg-accent/5");
            });
            this._zone.addEventListener("dragleave", () => {
              this._zone.classList.remove("border-accent", "bg-accent/5");
            });
            this._zone.addEventListener("drop", (e) => {
              e.preventDefault();
              this._zone.classList.remove("border-accent", "bg-accent/5");
              const files = e.dataTransfer?.files;
              if (files?.length > 0) {
                this._input.files = files;
                this._handleFile(files[0]);
              }
            });

            // File picked via input
            this._input.addEventListener("change", () => {
              if (this._input.files?.length > 0) {
                this._handleFile(this._input.files[0]);
              }
            });
          },

          _handleFile(file) {
            if (!file) return;

            if (file.size > 10 * 1024 * 1024) {
              alert("File must be under 10 MB.");
              return;
            }

            const reader = new FileReader();
            reader.onload = (e) => {
              const base64 = e.target.result.split(",")[1];
              this.pushEvent("cert_file_selected", {filename: file.name, base64: base64});
            };
            reader.readAsDataURL(file);
          }
        }
      </script>
    </Layouts.app>
    """
  end

  # ── Event handlers ──────────────────────────────────────────────────

  @impl true
  def handle_event("cert_file_selected", %{"filename" => filename, "base64" => b64}, socket) do
    {:noreply,
     socket
     |> assign(:uploading, true)
     |> assign(:current_cert, %{filename: filename, base64: b64})
     |> assign(:errors, [])}
  end

  @impl true
  def handle_event("validate_cert_upload", %{"cert_upload" => params}, socket) do
    password = Map.get(params, "password", "")
    {:noreply, assign(socket, :password, password)}
  end

  @impl true
  def handle_event("upload_cert", %{"cert_upload" => params}, socket) do
    password = Map.get(params, "password", "")

    case socket.assigns.current_cert do
      %{base64: b64} when is_binary(b64) and b64 != "" ->
        with {:ok, pfx_bytes} <- Base.decode64(b64),
             {:ok, _keys, certs} <- Pades.parse_keystore(pfx_bytes, password) do
          # Process each cert
          new_certs =
            Enum.map(certs, fn cert ->
              extract_cert_display_info(cert.der, cert.key_id)
            end)

          _new_idx = length(socket.assigns.certificates) + length(new_certs) - 1

          {:noreply,
           socket
           |> assign(:certificates, socket.assigns.certificates ++ new_certs)
           |> assign(:cert_info, List.first(new_certs))
           |> assign(:selected_cert_index, length(socket.assigns.certificates))
           |> assign(:errors, [])
           |> assign(:uploading, false)
           |> assign(:password, "")}
        else
          {:error, :bad_base64} ->
            {:noreply, assign(socket, :errors, ["Invalid file encoding."])}

          {:error, reason} when is_atom(reason) ->
            {:noreply, assign(socket, :errors, ["Failed to parse keystore: #{inspect(reason)}"])}

          {:error, reason} ->
            {:noreply, assign(socket, :errors, [to_string(reason)])}
        end

      _ ->
        {:noreply, assign(socket, :errors, ["Please select a file first."])}
    end
  end

  @impl true
  def handle_event("select_cert", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    certs = socket.assigns.certificates
    cert_info = Enum.at(certs, idx)

    {:noreply,
     socket
     |> assign(:selected_cert_index, idx)
     |> assign(:cert_info, cert_info)}
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp extract_cert_display_info(cert_der, key_id) do
    decoded = :public_key.pkix_decode_cert(cert_der, :plain)
    tbs = elem(decoded, 1)
    serial = elem(tbs, 2) |> Integer.to_string()

    subject = elem(tbs, 6)
    issuer = elem(tbs, 4)
    validity = elem(tbs, 5)

    subject_cn = extract_cn(subject)
    issuer_cn = extract_cn(issuer)

    {valid_from, valid_to} =
      case elem(validity, 1) do
        {:utcTime, from} ->
          {parse_utc_time(from), parse_utc_time(elem(elem(validity, 2), 1) |> elem(1))}

        from ->
          {parse_validity_time(from), parse_validity_time(elem(validity, 2))}
      end

    key_algo =
      case elem(tbs, 7) do
        {:SubjectPublicKeyInfo, {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 1}, _}, _} ->
          :rsa

        {:SubjectPublicKeyInfo, {:AlgorithmIdentifier, {1, 2, 840, 100_045, 2, 1}, _}, _} ->
          :ecdsa

        _ ->
          :unknown
      end

    %{
      der: cert_der,
      key_id: key_id,
      subject_cn: subject_cn,
      issuer_cn: issuer_cn,
      serial: serial,
      algorithm: key_algo,
      valid_from: valid_from,
      valid_to: valid_to
    }
  rescue
    _ ->
      %{
        der: cert_der,
        key_id: key_id,
        subject_cn: "Unknown",
        issuer_cn: "Unknown",
        serial: "0",
        algorithm: :unknown,
        valid_from: nil,
        valid_to: nil
      }
  end

  defp extract_cn({:rdnSequence, rdns}) do
    rdns
    |> Enum.find_value(fn {:AttributeTypeAndValue, {2, 5, 4, 3}, value} ->
      case value do
        {tag, s} when tag in [:printableString, :utf8String, :ia5String, :teletexString] ->
          to_string(s)

        _ ->
          nil
      end
    end)
  end

  defp parse_utc_time(s) when is_binary(s) and byte_size(s) == 13 do
    <<yy::binary-size(2), mm::binary-size(2), dd::binary-size(2), hh::binary-size(2),
      min::binary-size(2), ss::binary-size(2), "Z">> = s

    year = if String.to_integer(yy) >= 50, do: "19#{yy}", else: "20#{yy}"

    {:ok, dt, _} = DateTime.from_iso8601("#{year}-#{mm}-#{dd}T#{hh}:#{min}:#{ss}Z")
    dt
  rescue
    _ -> nil
  end

  defp parse_utc_time(_), do: nil

  defp parse_validity_time({:utcTime, s}), do: parse_utc_time(s)

  defp parse_validity_time({:generalizedTime, s}) do
    {:ok, dt, _} = DateTime.from_iso8601(s)
    dt
  rescue
    _ -> nil
  end

  defp parse_validity_time(_), do: nil

  defp format_date(nil), do: "N/A"

  defp format_date(dt) do
    Calendar.strftime(dt, "%b %d, %Y")
  end

  defp cert_expired?(nil), do: false

  defp cert_expired?(dt) do
    DateTime.compare(dt, DateTime.utc_now()) == :lt
  end

  defp cert_expiring_soon?(nil), do: false

  defp cert_expiring_soon?(dt) do
    diff = DateTime.diff(dt, DateTime.utc_now(), :day)
    diff > 0 and diff <= 30
  end
end
