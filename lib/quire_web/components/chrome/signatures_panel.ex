defmodule QuireWeb.Chrome.SignaturesPanel do
  @moduledoc """
  Signatures panel (plan3.md §9.4, T-114): a left-panel collapsible section
  with three signature capture modes — Draw, Type, Upload — plus a list of
  saved signatures.

  ## Modes

    * **Draw** — pointer-events canvas with pressure-aware smoothing.
      Captured strokes are serialised as curve data (points, thickness) and
      submitted to the server.

    * **Type** — five script fonts (Alex Brush, Pacifico, Caveat, Dancing
      Script, Satisfy). The typed text is converted to contour data on the
      server (via canvas rendering → contour extraction) and saved.

    * **Upload** — file picker with auto background removal (threshold to
      alpha). Format normalisation (PNG with transparency) happens
      server-side.

  Saved signatures persist in `user_settings.signatures` and are
  reselectable across sessions.
  """
  use Phoenix.Component

  import QuireWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  @doc """
  Renders the full signatures panel content.
  """
  attr :signatures, :list, default: []

  def signatures_panel(assigns) do
    ~H"""
    <div id="signatures-panel" class="flex-1 flex flex-col min-h-0">
      <%!-- Capture toolbar — tabs for each mode --%>
      <div
        class="flex border-b border-chrome-border dark:border-gray-600"
        role="tablist"
        aria-label="Signature capture mode"
      >
        <button
          type="button"
          role="tab"
          id="sig-tab-draw"
          phx-click={JS.toggle(to: "#sig-draw-content", out: "hidden", in: "hidden") |> JS.toggle(to: "#sig-type-content", in: "hidden") |> JS.toggle(to: "#sig-upload-content", in: "hidden")}
          class="flex-1 px-3 py-2 text-xs font-medium text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 border-b-2 border-transparent data-[active=true]:border-accent data-[active=true]:text-accent transition-all cursor-pointer"
          aria-controls="sig-draw-content"
        >
          Draw
        </button>
        <button
          type="button"
          role="tab"
          id="sig-tab-type"
          phx-click={JS.toggle(to: "#sig-draw-content", in: "hidden") |> JS.toggle(to: "#sig-type-content", out: "hidden", in: "hidden") |> JS.toggle(to: "#sig-upload-content", in: "hidden")}
          class="flex-1 px-3 py-2 text-xs font-medium text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 border-b-2 border-transparent data-[active=true]:border-accent data-[active=true]:text-accent transition-all cursor-pointer"
          aria-controls="sig-type-content"
        >
          Type
        </button>
        <button
          type="button"
          role="tab"
          id="sig-tab-upload"
          phx-click={JS.toggle(to: "#sig-draw-content", in: "hidden") |> JS.toggle(to: "#sig-type-content", in: "hidden") |> JS.toggle(to: "#sig-upload-content", out: "hidden", in: "hidden")}
          class="flex-1 px-3 py-2 text-xs font-medium text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 border-b-2 border-transparent data-[active=true]:border-accent data-[active=true]:text-accent transition-all cursor-pointer"
          aria-controls="sig-upload-content"
        >
          Upload
        </button>
      </div>

      <%!-- Draw capture (active by default) --%>
      <div id="sig-draw-content" class="flex flex-col p-3 gap-3">
        <div
          id="sig-draw-canvas-container"
          phx-hook="SignatureDraw"
          class="relative w-full aspect-[3/1] bg-gray-50 dark:bg-gray-900 border border-chrome-border dark:border-gray-600 rounded-lg overflow-hidden cursor-crosshair"
        >
          <canvas
            id="sig-draw-canvas"
            class="absolute inset-0 w-full h-full touch-none"
          />
          <div id="sig-draw-placeholder" class="absolute inset-0 flex items-center justify-center pointer-events-none">
            <p class="text-xs text-gray-400 dark:text-gray-500">Draw your signature</p>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <button
            type="button"
            id="sig-draw-clear"
            phx-hook="SignatureDrawClear"
            class="px-3 py-1.5 text-xs font-medium rounded-lg bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-300 dark:hover:bg-gray-600 transition-colors cursor-pointer"
          >
            Clear
          </button>
          <input
            type="text"
            id="sig-draw-label"
            placeholder="Label (optional)"
            class="flex-1 px-2 py-1.5 text-xs border border-chrome-border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 placeholder:text-gray-400"
          />
          <button
            type="button"
            id="sig-draw-save"
            phx-hook="SignatureDrawSave"
            class="px-3 py-1.5 text-xs font-medium rounded-lg bg-accent text-white hover:bg-accent/90 transition-colors cursor-pointer"
          >
            Save
          </button>
        </div>
      </div>

      <%!-- Type capture --%>
      <div id="sig-type-content" class="hidden flex-col p-3 gap-3">
        <div class="flex gap-2">
          <select
            id="sig-type-font"
            class="flex-1 px-2 py-1.5 text-xs border border-chrome-border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200"
          >
            <option value="Alex Brush">Alex Brush</option>
            <option value="Pacifico">Pacifico</option>
            <option value="Caveat">Caveat</option>
            <option value="Dancing Script">Dancing Script</option>
            <option value="Satisfy">Satisfy</option>
          </select>
          <input
            type="range"
            id="sig-type-size"
            min="24"
            max="72"
            value="48"
            class="w-16"
            aria-label="Font size"
          />
        </div>

        <input
          type="text"
          id="sig-type-input"
          placeholder="Type your signature"
          class="w-full px-3 py-2 text-lg border border-chrome-border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 placeholder:text-gray-400"
        />

        <div
          id="sig-type-preview"
          class="w-full min-h-[60px] flex items-center justify-center bg-gray-50 dark:bg-gray-900 border border-chrome-border dark:border-gray-600 rounded-lg overflow-hidden relative"
        >
          <canvas id="sig-type-preview-canvas" class="w-full h-full absolute inset-0" />
          <span
            id="sig-type-preview-text"
            class="text-gray-400 dark:text-gray-500 text-xs"
          >Preview</span>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".SignatureTypePreview">
          export default {
            mounted() {
              this._canvas = document.getElementById("sig-type-preview-canvas");
              this._ctx = this._canvas?.getContext("2d");
              this._input = document.getElementById("sig-type-input");
              this._fontSelect = document.getElementById("sig-type-font");
              this._sizeInput = document.getElementById("sig-type-size");
              this._placeholder = document.getElementById("sig-type-preview-text");

              if (!this._canvas || !this._input) return;

              const parent = this._canvas.parentElement;

              this._render = () => {
                const text = this._input.value.trim();
                if (!text) {
                  this._placeholder?.classList.remove("hidden");
                  this._ctx.clearRect(0, 0, parent.clientWidth, parent.clientHeight);
                  return;
                }
                this._placeholder?.classList.add("hidden");

                const font = this._fontSelect?.value || "Alex Brush";
                const size = parseInt(this._sizeInput?.value || "48", 10);
                const w = parent.clientWidth;
                const h = parent.clientHeight;

                const dpr = window.devicePixelRatio || 1;
                this._canvas.width = w * dpr;
                this._canvas.height = h * dpr;
                this._ctx.scale(dpr, dpr);

                this._ctx.clearRect(0, 0, w, h);
                this._ctx.textBaseline = "middle";
                this._ctx.textAlign = "center";
                this._ctx.font = `${size}px "${font}"`;
                this._ctx.fillStyle = "#000";
                this._ctx.fillText(text, w / 2, h / 2);
              };

              this._render();

              this._input.addEventListener("input", () => this._render());
              this._fontSelect?.addEventListener("change", () => this._render());
              this._sizeInput?.addEventListener("input", () => this._render());

              const ro = new ResizeObserver(() => this._render());
              ro.observe(parent);
            }
          }
        </script>

        <div class="flex items-center gap-2">
          <input
            type="text"
            id="sig-type-label"
            placeholder="Label (optional)"
            class="flex-1 px-2 py-1.5 text-xs border border-chrome-border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 placeholder:text-gray-400"
          />
          <button
            type="button"
            id="sig-type-save"
            phx-hook="SignatureTypeSave"
            class="px-3 py-1.5 text-xs font-medium rounded-lg bg-accent text-white hover:bg-accent/90 transition-colors cursor-pointer"
          >
            Save
          </button>
        </div>
      </div>

      <%!-- Upload capture --%>
      <div id="sig-upload-content" class="hidden flex-col p-3 gap-3">
        <div
          id="sig-upload-zone"
          phx-hook=".SignatureUpload"
          class="border-2 border-dashed border-chrome-border dark:border-gray-600 rounded-lg p-6 text-center hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors cursor-pointer"
        >
          <.icon name="hero-arrow-up-tray" class="size-8 text-gray-300 dark:text-gray-500 mx-auto mb-2" />
          <p class="text-xs text-gray-400 dark:text-gray-500">
            Click to upload an image, or drag and drop
          </p>
          <p class="text-xs text-gray-300 dark:text-gray-600 mt-1">PNG, JPG, WebP — max 5 MB</p>
          <input type="file" id="sig-upload-input" accept="image/png,image/jpeg,image/webp" class="hidden" />
        </div>

        <div id="sig-upload-preview" class="hidden w-full min-h-[60px] flex items-center justify-center bg-gray-50 dark:bg-gray-900 border border-chrome-border dark:border-gray-600 rounded-lg overflow-hidden">
        </div>

        <div class="flex items-center gap-2">
          <input
            type="text"
            id="sig-upload-label"
            placeholder="Label (optional)"
            class="flex-1 px-2 py-1.5 text-xs border border-chrome-border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 placeholder:text-gray-400"
          />
          <button
            type="button"
            id="sig-upload-save"
            phx-hook="SignatureUploadSave"
            class="px-3 py-1.5 text-xs font-medium rounded-lg bg-accent text-white hover:bg-accent/90 transition-colors cursor-pointer"
          >
            Save
          </button>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".SignatureUpload">
          export default {
            mounted() {
              this._input = document.getElementById("sig-upload-input");
              this._preview = document.getElementById("sig-upload-preview");
              this._dropZone = this.el;

              if (!this._input || !this._preview) return;

              // Click on drop zone → file picker
              this._dropZone.addEventListener("click", (e) => {
                if (e.target.tagName !== "INPUT") {
                  this._input.click();
                }
              });

              // Drag-over visual feedback
              this._dropZone.addEventListener("dragover", (e) => {
                e.preventDefault();
                this._dropZone.classList.add("border-accent", "bg-accent/5");
              });
              this._dropZone.addEventListener("dragleave", () => {
                this._dropZone.classList.remove("border-accent", "bg-accent/5");
              });
              this._dropZone.addEventListener("drop", (e) => {
                e.preventDefault();
                this._dropZone.classList.remove("border-accent", "bg-accent/5");
                const files = e.dataTransfer?.files;
                if (files?.length > 0) {
                  this._input.files = files;
                  this._handleFile(files[0]);
                }
              });

              // File selected via picker
              this._input.addEventListener("change", () => {
                if (this._input.files?.length > 0) {
                  this._handleFile(this._input.files[0]);
                }
              });
            },

            _handleFile(file) {
              if (!file || !file.type.startsWith("image/")) return;
              if (file.size > 5 * 1024 * 1024) {
                alert("Image must be under 5 MB.");
                return;
              }

              const reader = new FileReader();
              reader.onload = (e) => {
                const img = new Image();
                img.onload = () => {
                  // Offscreen canvas for background removal
                  const canvas = document.createElement("canvas");
                  canvas.width = img.width;
                  canvas.height = img.height;
                  const ctx = canvas.getContext("2d");
                  ctx.drawImage(img, 0, 0);

                  // Threshold-to-alpha: pixels near white → transparent
                  const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
                  const pixels = imageData.data;
                  const threshold = 240;
                  for (let i = 0; i < pixels.length; i += 4) {
                    if (pixels[i] >= threshold && pixels[i+1] >= threshold && pixels[i+2] >= threshold) {
                      pixels[i+3] = 0;
                    }
                  }
                  ctx.putImageData(imageData, 0, 0);

                  // Show preview
                  const dataUrl = canvas.toDataURL("image/png");
                  this._preview.innerHTML = `<img src="${dataUrl}" class="max-w-full max-h-32 object-contain" alt="Upload preview" />`;
                  this._preview.classList.remove("hidden");

                  // Store for Save button
                  this._preview.dataset.pngBase64 = dataUrl.split(",")[1];
                };
                img.src = e.target.result;
              };
              reader.readAsDataURL(file);
            }
          }
        </script>
      </div>

      <%!-- Saved signatures list --%>
      <div class="border-t border-chrome-border dark:border-gray-600">
        <div class="px-4 py-2 text-xs font-medium text-gray-600 dark:text-gray-400 uppercase tracking-wider flex items-center justify-between">
          <span>Saved ({length(@signatures)})</span>
        </div>

        <div class="overflow-y-auto max-h-48">
          <div
            :for={sig <- @signatures}
            id={"saved-sig-#{sig["id"]}"}
            class="flex items-center gap-2 px-4 py-2 hover:bg-gray-50 dark:hover:bg-gray-700/50 group transition-colors"
          >
            <%!-- Signature thumbnail / icon --%>
            <div class="w-10 h-8 flex items-center justify-center rounded border border-chrome-border dark:border-gray-600 bg-white dark:bg-gray-800 shrink-0 overflow-hidden">
              <%= case sig["type"] do %>
                <% ty when ty in ~w(draw type) -> %>
                  <span class="text-[10px] text-gray-400 italic truncate px-1 leading-tight text-center">
                    {sig["label"] || "sig"}
                  </span>
                <% "upload" -> %>
                  <img
                    :if={is_binary(get_in(sig, ["data", "preview"]))}
                    src={"data:image/png;base64,#{sig["data"]["preview"]}"}
                    class="w-full h-full object-contain"
                    alt={sig["label"]}
                  />
                  <span :if={!is_binary(get_in(sig, ["data", "preview"]))} class="text-[10px] text-gray-400">
                    img
                  </span>
              <% end %>
            </div>

            <%!-- Label --%>
            <div class="flex-1 min-w-0">
              <p class="text-sm text-gray-700 dark:text-gray-200 truncate">{sig["label"]}</p>
              <p class="text-[10px] text-gray-400 capitalize">{sig["type"]} signature</p>
            </div>

            <%!-- Actions --%>
            <div class="flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
              <button
                type="button"
                phx-click="signature_use"
                phx-value-id={sig["id"]}
                class="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors cursor-pointer"
                aria-label={"Use #{sig["label"]}"}
                title="Place on page"
              >
                <.icon name="hero-cursor-arrow-rays" class="size-4 text-accent" />
              </button>
              <button
                type="button"
                phx-click="delete_signature"
                phx-value-id={sig["id"]}
                class="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors cursor-pointer"
                aria-label={"Delete #{sig["label"]}"}
                title="Delete"
              >
                <.icon name="hero-trash" class="size-4 text-gray-400 hover:text-red-500" />
              </button>
            </div>
          </div>

          <div :if={@signatures == []} class="px-4 py-6 text-center">
            <p class="text-xs text-gray-400 dark:text-gray-500">No saved signatures yet</p>
            <p class="text-xs text-gray-300 dark:text-gray-600 mt-1">
              Use Draw, Type, or Upload above to create one
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
