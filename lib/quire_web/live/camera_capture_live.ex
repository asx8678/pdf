defmodule QuireWeb.CameraCaptureComponent do
  @moduledoc ~S"""
  LiveComponent for camera scanning via WebRTC.

  Manages the full camera capture lifecycle:
    * `idle` — component initialised, awaiting mount
    * `requesting_permission` — getUserMedia in progress
    * `error` — camera denied or unavailable
    * `capturing` — live preview showing, ready to take a photo
    * `captured` — photo taken, showing confirm/retake
    * `processing` — image sent for OCR, awaiting result

  The colocated hook `.CameraCapture` handles all WebRTC operations and
  communicates back via LiveView pushEvent.
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
       camera_height: @default_height
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
    # Parent LiveView will push start_camera to the hook via push_event
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
    data_url = socket.assigns.captured_data_url

    if data_url do
      # Send image data to parent LiveView for OCR processing
      send(self(), {:scan_image, data_url, socket.assigns[:title] || "Scan"})
    end

    {:noreply, assign(socket, :phase, :processing)}
  end

  @impl true
  def handle_event("close_camera", _params, socket) do
    send(self(), {:close_camera_modal})
    {:noreply, socket |> assign(:phase, :idle) |> assign(:captured_data_url, nil)}
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
      <%= case @phase do %>
        <% :idle -> %>
          <.idle_state />
        <% :requesting_permission -> %>
          <.loading_state message="Requesting camera access…" />
        <% :error -> %>
          <.error_state
            message={@error_message || "Camera unavailable or permission denied."}
            on_retry="camera_requested"
          />
        <% :capturing -> %>
          <.capturing_view />
        <% :captured -> %>
          <.captured_view
            data_url={@captured_data_url}
            on_retake="retake"
            on_confirm="confirm"
          />
        <% :processing -> %>
          <.loading_state message="Sending image for OCR…" />
      <% end %>
    </div>
    """
  end

  # ── Sub-components ────────────────────────────────────────────────────

  defp idle_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 gap-4">
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
  attr :on_retry, :string, default: "camera_requested"

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
          phx-click={@on_retry}
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
      </div>
      <div class="flex items-center gap-3">
        <button
          type="button"
          id="capture-btn-\#{@id}"
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

  attr :data_url, :string, required: true
  attr :on_retake, :string, required: true
  attr :on_confirm, :string, required: true

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
          phx-click={@on_retake}
          phx-target={@myself}
          aria-label="Retake photo"
          class="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium border border-chrome-border dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors cursor-pointer"
        >
          <.icon name="hero-arrow-uturn-left" class="size-4" />
          <span>Retake</span>
        </button>
        <button
          type="button"
          phx-click={@on_confirm}
          phx-target={@myself}
          aria-label="Confirm and process scan"
          class="inline-flex items-center gap-2 px-5 py-2 rounded-lg text-sm font-medium bg-accent text-white hover:bg-accent-hover transition-colors cursor-pointer"
        >
          <.icon name="hero-check" class="size-4" />
          <span>Confirm</span>
        </button>
      </div>
      <p class="text-xs text-gray-500 dark:text-gray-400">
        Check that the document is clear and well-framed.
      </p>
    </div>
    """
  end
end
