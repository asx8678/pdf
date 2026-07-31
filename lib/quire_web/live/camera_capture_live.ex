defmodule QuireWeb.CameraCaptureComponent do
  @moduledoc ~S"""
  LiveComponent for scanning a document to PDF (§9.2, T-080).

  Two capture paths feed the **same** image→PDF pipeline (`Quire.Scan`):

    * WebRTC camera preview (colocated hook `.CameraCapture`) with a live
      Sobel edge-detection overlay to help frame the document
    * a file input with `capture="environment"` so mobile browsers can shoot
      straight from the camera app

  Both carry the same scan options — deskew (server-side via vix), a contrast
  preset, and an optional "make searchable" OCR step (T-144) — and both report
  back through the parent LiveView with the captured JPEG data URL.

  Lifecycle phases: `:idle`, `:requesting_permission`, `:error`,
  `:capturing`, `:captured`, `:processing`.
  """

  use QuireWeb, :live_component

  @default_width 1280
  @default_height 720

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       phase: :idle,
       error_message: nil,
       captured_data_url: nil,
       camera_width: @default_width,
       camera_height: @default_height,
       deskew: true,
       contrast: "auto",
       ocr: false
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, socket}
  end

  # ── Event handlers ──────────────────────────────────────────────────────

  @impl true
  def handle_event("camera_requested", _params, socket) do
    send(self(), {:request_camera})
    {:noreply, assign(socket, :phase, :requesting_permission)}
  end

  @impl true
  def handle_event("retake", _params, socket) do
    {:noreply,
     socket
     |> assign(:phase, :capturing)
     |> assign(:captured_data_url, nil)}
  end

  @impl true
  def handle_event("confirm", _params, socket) do
    if data_url = socket.assigns.captured_data_url do
      send(self(), {:scan_image, data_url, socket.assigns[:title] || "Scan", scan_opts(socket)})
    end

    {:noreply, assign(socket, :phase, :processing)}
  end

  @impl true
  def handle_event("close_camera", _params, socket) do
    send(self(), {:close_camera_modal})
    {:noreply, socket |> assign(:phase, :idle) |> assign(:captured_data_url, nil)}
  end

  @impl true
  def handle_event("toggle_deskew", _params, socket) do
    {:noreply, update(socket, :deskew, &(!&1))}
  end

  @impl true
  def handle_event("set_contrast", %{"contrast" => value}, socket) do
    {:noreply, assign(socket, :contrast, value)}
  end

  @impl true
  def handle_event("toggle_ocr", _params, socket) do
    {:noreply, update(socket, :ocr, &(!&1))}
  end

  @impl true
  def handle_event("use_file_source", _params, socket) do
    {:noreply, push_event(socket, "trigger_scan_file", %{})}
  end

  # ── Rendering ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".CameraCapture"
      class="camera-capture-component"
      data-camera-width={@camera_width}
      data-camera-height={@camera_height}
    >
      <.scan_options
        id={@id}
        deskew={@deskew}
        contrast={@contrast}
        ocr={@ocr}
        disabled={@phase in [:captured, :processing]}
        myself={@myself}
      />

      <%= case @phase do %>
        <% :idle -> %>
          <.idle_state myself={@myself} />
        <% :requesting_permission -> %>
          <.loading_state message="Requesting camera access…" />
        <% :error -> %>
          <.error_state
            message={@error_message || "Camera unavailable or permission denied."}
            myself={@myself}
          />
        <% :capturing -> %>
          <.capturing_view id={@id} />
        <% :captured -> %>
          <.captured_view
            id={@id}
            data_url={@captured_data_url}
            myself={@myself}
          />
        <% :processing -> %>
          <.loading_state message={if @ocr, do: "Running OCR…", else: "Building PDF…"} />
      <% end %>

      <%!-- File input with camera capture (mobile: opens the camera app) --%>
      <div class="mt-3 border-t border-chrome-border dark:border-gray-700 pt-3">
        <p class="text-xs text-gray-500 dark:text-gray-400 mb-2">
          Or capture with the file picker / camera app:
        </p>
        <.file_capture_input
          id={@id}
          deskew={@deskew}
          contrast={@contrast}
          ocr={@ocr}
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  # ── Sub-components ────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :deskew, :boolean, required: true
  attr :contrast, :string, required: true
  attr :ocr, :boolean, required: true
  attr :disabled, :boolean, required: true
  attr :myself, :any, required: true

  defp scan_options(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-5 gap-y-2 px-1 pb-3 text-sm">
      <label class="inline-flex items-center gap-2 cursor-pointer select-none">
        <input
          type="checkbox"
          id={"scan-deskew-#{@id}"}
          checked={@deskew}
          disabled={@disabled}
          phx-click="toggle_deskew"
          phx-target={@myself}
          class="size-4 rounded border-gray-300 text-accent focus:ring-accent/40 disabled:opacity-50"
        />
        <span class="text-gray-700 dark:text-gray-200">Deskew</span>
        <span
          class="text-xs text-gray-400 dark:text-gray-500"
          title="Straighten a crooked photo server-side via vix"
        >
          (server-side)
        </span>
      </label>

      <label class="inline-flex items-center gap-2">
        <span class="text-gray-700 dark:text-gray-200">Contrast</span>
        <select
          id={"scan-contrast-#{@id}"}
          phx-change="set_contrast"
          phx-target={@myself}
          disabled={@disabled}
          class="rounded-lg border border-chrome-border dark:border-gray-600 bg-white dark:bg-gray-800 px-2 py-1 text-sm text-gray-700 dark:text-gray-200 disabled:opacity-50"
        >
          <option value="none" selected={@contrast == "none"}>None</option>
          <option value="auto" selected={@contrast == "auto"}>Auto</option>
          <option value="high" selected={@contrast == "high"}>High</option>
          <option value="low" selected={@contrast == "low"}>Low</option>
          <option value="bw" selected={@contrast == "bw"}>Black &amp; white</option>
        </select>
      </label>

      <label class="inline-flex items-center gap-2 cursor-pointer select-none">
        <input
          type="checkbox"
          id={"scan-ocr-#{@id}"}
          checked={@ocr}
          disabled={@disabled}
          phx-click="toggle_ocr"
          phx-target={@myself}
          class="size-4 rounded border-gray-300 text-accent focus:ring-accent/40 disabled:opacity-50"
        />
        <span class="text-gray-700 dark:text-gray-200">Make searchable (OCR)</span>
      </label>
    </div>
    """
  end

  attr :myself, :any, required: true

  defp idle_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-8 gap-4">
      <div class="flex flex-col items-center gap-2 text-center">
        <.icon name="hero-camera" class="size-12 text-gray-300 dark:text-gray-600" />
        <p class="text-sm text-gray-500 dark:text-gray-400">
          Use your device camera to capture a document page.
        </p>
      </div>
      <button
        type="button"
        phx-click="camera_requested"
        phx-target={@myself}
        aria-label="Open camera"
        class="inline-flex items-center gap-2 px-5 py-2.5 rounded-lg text-sm font-medium bg-accent text-white hover:bg-accent-hover transition-colors cursor-pointer"
      >
        <.icon name="hero-camera" class="size-4" />
        <span>Open Camera</span>
      </button>
    </div>
    """
  end

  attr :message, :string, default: "Loading…"

  defp loading_state(assigns) do
    ~H"""
    <div class="flex items-center justify-center py-16" role="status">
      <div class="flex flex-col items-center gap-3">
        <.icon name="hero-arrow-path" class="size-6 text-accent animate-spin" />
        <span class="text-sm text-gray-500 dark:text-gray-400">{@message}</span>
      </div>
    </div>
    """
  end

  attr :message, :string, required: true
  attr :myself, :any, required: true

  defp error_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 px-6" role="alert">
      <div class="flex flex-col items-center gap-3 text-center">
        <.icon name="hero-exclamation-circle" class="size-10 text-red-400" />
        <p class="text-sm text-gray-700 dark:text-gray-300">{@message}</p>
        <p class="text-xs text-gray-500 dark:text-gray-400">
          Ensure your browser has camera permission and no other app is using the camera.
        </p>
        <button
          type="button"
          phx-click="camera_requested"
          phx-target={@myself}
          aria-label="Retry camera access"
          class="mt-2 inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg border border-chrome-border dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors cursor-pointer"
        >
          <.icon name="hero-arrow-path" class="size-3.5" />
          <span>Retry</span>
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true

  defp capturing_view(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-4">
      <div class="relative bg-black rounded-xl overflow-hidden max-w-full">
        <video
          id={"camera-preview-#{@id}"}
          autoplay
          playsinline
          class="max-w-full max-h-[50vh] object-contain"
          aria-label="Camera preview"
        />
        <%!-- Live edge-detection overlay (Sobel, drawn by the .CameraCapture hook) --%>
        <canvas
          id={"edge-overlay-#{@id}"}
          class="pointer-events-none absolute inset-0 w-full h-full"
          aria-hidden="true"
        />
      </div>
      <p class="text-xs text-gray-500 dark:text-gray-400 -mt-2">
        Green highlights show detected document edges — line the page up with them.
      </p>
      <div class="flex items-center gap-3">
        <button
          type="button"
          id={"capture-btn-#{@id}"}
          aria-label="Capture photo"
          class="inline-flex items-center justify-center size-14 rounded-full bg-accent text-white hover:bg-accent-hover transition-colors shadow-lg cursor-pointer"
        >
          <div class="size-10 rounded-full border-2 border-white" />
        </button>
      </div>
      <p class="text-xs text-gray-500 dark:text-gray-400">
        Position the document in the frame, then press the capture button.
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :data_url, :string, required: true
  attr :myself, :any, required: true

  defp captured_view(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-4">
      <div class="relative bg-gray-100 dark:bg-gray-700 rounded-xl overflow-hidden max-w-full">
        <img
          src={@data_url}
          alt="Captured document"
          class="max-w-full max-h-[50vh] object-contain"
        />
      </div>
      <div class="flex items-center gap-3">
        <button
          type="button"
          phx-click="retake"
          phx-target={@myself}
          aria-label="Retake photo"
          class="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium border border-chrome-border dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors cursor-pointer"
        >
          <.icon name="hero-arrow-uturn-left" class="size-4" />
          <span>Retake</span>
        </button>
        <button
          type="button"
          phx-click="confirm"
          phx-target={@myself}
          aria-label="Confirm and process scan"
          class="inline-flex items-center gap-2 px-5 py-2 rounded-lg text-sm font-medium bg-accent text-white hover:bg-accent-hover transition-colors cursor-pointer"
        >
          <.icon name="hero-check" class="size-4" />
          <span>Build PDF</span>
        </button>
      </div>
      <p class="text-xs text-gray-500 dark:text-gray-400">
        Check that the document is clear and well-framed.
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :deskew, :boolean, required: true
  attr :contrast, :string, required: true
  attr :ocr, :boolean, required: true
  attr :myself, :any, required: true

  defp file_capture_input(assigns) do
    ~H"""
    <input
      type="file"
      id={"scan-file-input-#{@id}"}
      accept="image/png,image/jpeg,image/webp"
      capture="environment"
      class="hidden"
      phx-hook=".ScanFileInput"
      data-deskew={@deskew}
      data-contrast={@contrast}
      data-ocr={@ocr}
    />
    <button
      type="button"
      phx-click="use_file_source"
      phx-target={@myself}
      aria-label="Choose an image or capture with the camera app"
      class="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium border border-chrome-border dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors cursor-pointer"
    >
      <.icon name="hero-photo" class="size-4" />
      <span>Take photo / choose image</span>
    </button>
    """
  end

  defp scan_opts(socket) do
    %{
      deskew: socket.assigns.deskew,
      contrast: socket.assigns.contrast,
      ocr: socket.assigns.ocr
    }
  end
end
