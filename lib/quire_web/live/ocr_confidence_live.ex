defmodule QuireWeb.OcrConfidenceLive do
  use QuireWeb, :live_component

  def render(assigns) do
    ~H"""
    <div id="ocr-confidence-component">
      <.header>
        OCR Confidence
      </.header>
      <div class="p-4">
        <%= if @ocr_running do %>
          <p class="text-sm text-gray-500">OCR in progress…</p>
        <% else %>
          <% result = @ocr_result %>
          <div :if={result} class="space-y-2">
            <p class="text-sm text-gray-500">
              Confidence: {if result.confidence, do: "#{round(result.confidence * 100)}%", else: "N/A"}
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def handle_event("dismiss", _params, socket) do
    send(self(), {:dismiss_ocr_confidence})
    {:noreply, socket}
  end
end
