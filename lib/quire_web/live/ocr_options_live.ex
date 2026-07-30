defmodule QuireWeb.OcrOptionsLive do
  @moduledoc """
  OCR options control panel (§9.10).

  A LiveComponent embedded in the workspace ribbon strip.  Shows language
  multi-select, output mode, deskew, auto-rotate, clean/denoise, and image
  optimisation level.

  ## States

    * `:loading` — checking Tesseract availability and installed languages
    * `:error` — Tesseract not available; plain-language message, no raw output
    * `:empty` — no options to show (e.g. no document open)
    * `:ready` — normal state with all options exposed

  Defaults come from the user's settings or built-in fallbacks.
  """

  use QuireWeb, :live_component

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

  @output_modes [
    %{
      id: "skip",
      label: "Skip pages with text",
      description: "Only OCR pages that have no text layer"
    },
    %{id: "redo", label: "Redo all", description: "Re-run OCR on every page"},
    %{id: "force", label: "Force overwrite", description: "Overwrite existing text regardless"}
  ]

  @optimise_levels [
    %{value: 0, label: "None", description: "No optimisation"},
    %{value: 1, label: "Balanced", description: "Good quality and size"},
    %{value: 2, label: "Quality", description: "Higher quality, larger output"},
    %{value: 3, label: "Size", description: "Smaller output, may lose some detail"}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       status: :loading,
       languages: [],
       selected_languages: ["eng"],
       output_mode: "skip",
       deskew: true,
       auto_rotate: true,
       clean: true,
       optimise_level: 1,
       download_states: %{},
       download_errors: %{}
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns.status == :ready or socket.assigns.status == :loading do
        socket
        |> probe_languages()
        |> load_defaults()
      else
        socket
        |> load_defaults()
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_language", %{"lang" => lang}, socket) do
    current = socket.assigns.selected_languages

    if lang in current do
      # Removing language — just remove from selection
      {:noreply, assign(socket, :selected_languages, List.delete(current, lang))}
    else
      # Adding language — ensure it is downloaded
      already_ready? =
        Map.get(socket.assigns.download_states, lang) == :ready or
          Image.OCR.Tessdata.installed?(lang, datapath: Quire.Ocr.Tessdata.cache_root())

      socket =
        socket
        |> assign(:selected_languages, [lang | current])
        |> put_download_state(lang, :ready)

      if already_ready? do
        {:noreply, socket}
      else
        socket = put_download_state(socket, lang, :downloading)

        # Start async download in a Task; the result comes back as {:ensure_result, lang, status}
        send(self(), {:ensure_tessdata, lang})

        {:noreply, socket}
      end
    end
  end

  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ~w(skip redo force) do
    {:noreply, assign(socket, :output_mode, mode)}
  end

  def handle_event("toggle_deskew", _params, socket) do
    {:noreply, assign(socket, :deskew, !socket.assigns.deskew)}
  end

  def handle_event("toggle_auto_rotate", _params, socket) do
    {:noreply, assign(socket, :auto_rotate, !socket.assigns.auto_rotate)}
  end

  def handle_event("toggle_clean", _params, socket) do
    {:noreply, assign(socket, :clean, !socket.assigns.clean)}
  end

  def handle_event("set_optimise", %{"level" => level}, socket) do
    level = String.to_integer(level)

    level =
      case level do
        l when l < 0 -> 0
        l when l > 3 -> 3
        l -> l
      end

    {:noreply, assign(socket, :optimise_level, level)}
  end

  def handle_event("run_ocr", _params, socket) do
    languages = socket.assigns.selected_languages |> Enum.sort() |> Enum.join("+")

    options = %{
      languages: languages,
      mode: socket.assigns.output_mode,
      deskew: socket.assigns.deskew,
      rotate: socket.assigns.auto_rotate,
      clean: socket.assigns.clean,
      optimise: socket.assigns.optimise_level
    }

    send(self(), {:run_ocr, options})

    {:noreply, socket}
  end

  def handle_event("retry_probe", _params, socket) do
    {:noreply, socket |> assign(status: :loading) |> probe_languages()}
  end

  # ── Tessdata download handling ───────────────────────────────────────

  # LiveComponents support handle_info/2 even though the behaviour does not
  # declare it as a required callback.
  def handle_info({:ensure_tessdata, lang}, socket) do
    # Run the download in a separate task so the LiveView process is not
    # blocked by network I/O.  The result is sent back as a message.
    live_view_pid = self()

    Task.start(fn ->
      result = Quire.Ocr.Tessdata.ensure(lang)
      send(live_view_pid, {:ensure_result, lang, result})
    end)

    {:noreply, socket}
  end

  def handle_info({:ensure_result, lang, result}, socket) do
    socket =
      case result do
        {:ok, _status} ->
          socket |> put_download_state(lang, :ready) |> put_download_error(lang, nil)

        {:error, reason} ->
          error_msg = user_download_error(reason)
          socket |> put_download_state(lang, :error) |> put_download_error(lang, error_msg)
      end

    {:noreply, socket}
  end

  defp put_download_state(socket, lang, state) do
    assign(socket, :download_states, Map.put(socket.assigns.download_states, lang, state))
  end

  defp put_download_error(socket, lang, msg) do
    errors =
      if msg,
        do: Map.put(socket.assigns.download_errors, lang, msg),
        else: Map.delete(socket.assigns.download_errors, lang)

    assign(socket, :download_errors, errors)
  end

  defp user_download_error({:http_status, status}) do
    "Download failed (HTTP #{status}). Check your internet connection and try again."
  end

  defp user_download_error({:http_error, reason}) when is_atom(reason) do
    "Download failed: #{reason}. Please check your network connection."
  end

  defp user_download_error({:http_error, reason}) do
    "Download failed: #{inspect(reason)}. Please check your network connection."
  end

  defp user_download_error(:hash_mismatch) do
    "Downloaded file is corrupt. Please try again."
  end

  defp user_download_error(reason) when is_binary(reason) do
    reason
  end

  defp user_download_error(reason) do
    "Could not download language pack: #{inspect(reason)}."
  end

  # ── Rendering ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:output_modes, @output_modes)
      |> assign(:optimise_levels, @optimise_levels)

    ~H"""
    <div id={@id} role="region" aria-label="OCR options" class="ocr-options-panel min-w-[320px]">
      <%= case @status do %>
        <% :loading -> %>
          <.loading_state />
        <% :error -> %>
          <.error_state on_retry="retry_probe" />
        <% :empty -> %>
          <.empty_state />
        <% :ready -> %>
          <.options_form
            selected_languages={@selected_languages}
            languages={@languages}
            output_modes={@output_modes}
            output_mode={@output_mode}
            deskew={@deskew}
            auto_rotate={@auto_rotate}
            clean={@clean}
            optimise_levels={@optimise_levels}
            optimise_level={@optimise_level}
            ocr_running={@ocr_running}
            download_states={@download_states}
            download_errors={@download_errors}
          />
      <% end %>
    </div>
    """
  end

  # ── Sub-components ────────────────────────────────────────────────────

  defp loading_state(assigns) do
    ~H"""
    <div
      class="flex items-center justify-center py-12"
      role="status"
      aria-label="Checking Tesseract availability"
    >
      <div class="flex flex-col items-center gap-3">
        <.icon name="hero-arrow-path" class="size-6 text-accent animate-spin" />
        <span class="text-sm text-gray-500 dark:text-gray-400">Checking OCR languages…</span>
      </div>
    </div>
    """
  end

  attr :on_retry, :string, required: true

  defp error_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 px-6" role="alert">
      <div class="flex flex-col items-center gap-3 text-center">
        <.icon name="hero-exclamation-triangle" class="size-8 text-amber-500" />
        <p class="text-sm text-gray-700 dark:text-gray-300">
          OCR is not available on this system. Tesseract may not be installed.
        </p>
        <p class="text-xs text-gray-500 dark:text-gray-400">
          Please install Tesseract and Leptonica, then try again.
        </p>
        <button
          type="button"
          phx-click={@on_retry}
          phx-target={@myself}
          aria-label="Retry checking OCR availability"
          class="mt-2 inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg border border-chrome-border dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors cursor-pointer"
        >
          <.icon name="hero-arrow-path" class="size-3.5" />
          <span>Retry</span>
        </button>
      </div>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="py-8 text-center">
      <p class="text-sm text-gray-400 dark:text-gray-500">No OCR languages found on this system</p>
    </div>
    """
  end

  attr :selected_languages, :list, required: true
  attr :languages, :list, required: true
  attr :output_modes, :list, required: true
  attr :output_mode, :string, required: true
  attr :deskew, :boolean, required: true
  attr :auto_rotate, :boolean, required: true
  attr :clean, :boolean, required: true
  attr :optimise_levels, :list, required: true
  attr :optimise_level, :integer, required: true
  attr :ocr_running, :boolean, default: false
  attr :download_states, :map, default: %{}
  attr :download_errors, :map, default: %{}

  defp options_form(assigns) do
    ~H"""
    <div class="ocr-options-form p-4 space-y-5">
      <!-- Language multi-select -->
      <fieldset>
        <legend class="text-xs font-semibold text-gray-700 dark:text-gray-200 mb-2 uppercase tracking-wide">
          Languages
        </legend>
        <div class="flex flex-wrap gap-1.5" role="group" aria-label="Select OCR languages">
          <button
            :for={lang <- @languages}
            type="button"
            role="checkbox"
            aria-checked={lang.code in @selected_languages}
            aria-label={"#{lang.label} (#{lang.code})"}
            phx-click="toggle_language"
            phx-value-lang={lang.code}
            phx-target={@myself}
            disabled={Map.get(@download_states, lang.code) == :downloading}
            class={[
              "px-2.5 py-1 text-xs rounded-full border transition-colors",
              download_button_classes(
                lang.code,
                @selected_languages,
                @download_states,
                @download_errors
              )
            ]}
          >
            <span
              :if={Map.get(@download_states, lang.code) == :downloading}
              class="inline-block size-3 border-2 border-current border-t-transparent rounded-full animate-spin mr-1"
            />
            {lang.label}
          </button>
        </div>
        <div :for={{lang, error} <- @download_errors} class="mt-1 flex items-center gap-1.5">
          <span class="text-xs text-red-600 dark:text-red-400">
            {error}
          </span>
        </div>
        <p :if={@selected_languages == []} class="mt-1.5 text-xs text-amber-600 dark:text-amber-400">
          At least one language must be selected.
        </p>
      </fieldset>

      <!-- Output mode -->
      <fieldset>
        <legend class="text-xs font-semibold text-gray-700 dark:text-gray-200 mb-2 uppercase tracking-wide">
          Output mode
        </legend>
        <div class="space-y-1" role="radiogroup" aria-label="OCR output mode">
          <.mode_option
            :for={mode <- @output_modes}
            mode={mode}
            checked={mode.id == @output_mode}
          />
        </div>
      </fieldset>

      <!-- Toggle switches -->
      <fieldset>
        <legend class="text-xs font-semibold text-gray-700 dark:text-gray-200 mb-2 uppercase tracking-wide">
          Options
        </legend>
        <div class="space-y-1">
          <.toggle_option
            id="ocr-deskew"
            label="Deskew"
            checked={@deskew}
            event="toggle_deskew"
            description="Correct page skew before OCR"
          />
          <.toggle_option
            id="ocr-auto-rotate"
            label="Auto-rotate"
            checked={@auto_rotate}
            event="toggle_auto_rotate"
            description="Detect and correct page orientation"
          />
          <.toggle_option
            id="ocr-clean"
            label="Clean / Denoise"
            checked={@clean}
            event="toggle_clean"
            description="Remove speckles and background noise"
          />
        </div>
      </fieldset>

      <!-- Optimisation level slider -->
      <fieldset>
        <legend class="text-xs font-semibold text-gray-700 dark:text-gray-200 mb-2 uppercase tracking-wide">
          Image optimisation
        </legend>
        <div class="px-1">
          <div class="flex justify-between mb-1">
            <span class="text-xs text-gray-500 dark:text-gray-400">None</span>
            <span class="text-xs text-gray-500 dark:text-gray-400">Size</span>
          </div>
          <input
            type="range"
            min="0"
            max="3"
            step="1"
            value={@optimise_level}
            phx-click="set_optimise"
            phx-value-level={@optimise_level}
            phx-target={@myself}
            aria-label="Image optimisation level"
            class="w-full h-1.5 bg-gray-200 dark:bg-gray-600 rounded-full appearance-none cursor-pointer accent-accent"
          />
          <div class="flex justify-between mt-1">
            <.optimise_label
              :for={lvl <- @optimise_levels}
              level={lvl}
              current={@optimise_level}
            />
          </div>
        </div>
      </fieldset>

      <!-- Run button -->
      <div class="pt-2 border-t border-chrome-border dark:border-gray-600">
        <button
          type="button"
          phx-click="run_ocr"
          phx-target={@myself}
          disabled={
            ocr_can_run?(@selected_languages, @download_states, @download_errors, @ocr_running) ==
              false
          }
          aria-label={
            cond do
              @ocr_running ->
                "OCR is already running"

              has_download_errors?(@selected_languages, @download_errors) ->
                "Some languages failed to download"

              has_downloading?(@selected_languages, @download_states) ->
                "Downloading language packs…"

              @selected_languages == [] ->
                "Select at least one language to run OCR"

              true ->
                "Run OCR with selected options"
            end
          }
          class={[
            "w-full inline-flex items-center justify-center gap-2 px-4 py-2 rounded-lg text-sm font-medium transition-colors",
            if(ocr_can_run?(@selected_languages, @download_states, @download_errors, @ocr_running),
              do: "bg-accent text-accent-fg hover:bg-accent-hover cursor-pointer",
              else: "bg-gray-300 dark:bg-gray-700 text-gray-500 dark:text-gray-400 cursor-not-allowed"
            )
          ]}
        >
          <.icon name="hero-document-magnifying-glass" class="size-4" />
          <span>{if @ocr_running, do: "OCR running…", else: "Run OCR"}</span>
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, required: true
  attr :event, :string, required: true
  attr :description, :string, default: nil

  defp toggle_option(assigns) do
    ~H"""
    <label
      for={@id}
      class="flex items-center gap-3 py-1.5 px-2 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors cursor-pointer group"
    >
      <button
        id={@id}
        type="button"
        role="switch"
        aria-checked={@checked}
        aria-label={@label}
        phx-click={@event}
        phx-target={@myself}
        class={[
          "relative inline-flex h-5 w-9 shrink-0 rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-accent/40 focus:ring-offset-1",
          if(@checked,
            do: "bg-accent",
            else: "bg-gray-200 dark:bg-gray-600"
          )
        ]}
      >
        <span class={[
          "pointer-events-none inline-block h-4 w-4 rounded-full bg-white shadow transform ring-0 transition duration-200 ease-in-out",
          if(@checked, do: "translate-x-4", else: "translate-x-0")
        ]} />
      </button>
      <div class="flex flex-col leading-tight">
        <span class="text-xs font-medium text-gray-700 dark:text-gray-200 group-hover:text-gray-900 dark:group-hover:text-gray-100">
          {@label}
        </span>
        <span :if={@description} class="text-[11px] text-gray-500 dark:text-gray-400">
          {@description}
        </span>
      </div>
    </label>
    """
  end

  attr :mode, :map, required: true
  attr :checked, :boolean, required: true

  defp mode_option(assigns) do
    ~H"""
    <label class="flex items-start gap-2.5 py-1.5 px-2 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors cursor-pointer group">
      <input
        type="radio"
        name="ocr-mode"
        value={@mode.id}
        checked={@checked}
        phx-click="set_mode"
        phx-value-mode={@mode.id}
        phx-target={@myself}
        aria-label={@mode.label}
        class="mt-0.5 accent-accent cursor-pointer"
      />
      <div class="flex flex-col leading-tight">
        <span class="text-xs font-medium text-gray-700 dark:text-gray-200 group-hover:text-gray-900 dark:group-hover:text-gray-100">
          {@mode.label}
        </span>
        <span class="text-[11px] text-gray-500 dark:text-gray-400">{@mode.description}</span>
      </div>
    </label>
    """
  end

  attr :level, :map, required: true
  attr :current, :integer, required: true

  defp optimise_label(assigns) do
    ~H"""
    <span class={[
      "text-[10px] leading-tight text-center",
      if(@level.value == @current,
        do: "font-semibold text-accent",
        else: "text-gray-400 dark:text-gray-500"
      )
    ]}>
      {@level.label}
    </span>
    """
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp probe_languages(socket) do
    socket = assign(socket, status: :loading, languages: [])

    case check_tesseract() do
      {:ok, installed} ->
        languages = build_language_list(installed)

        if languages == [] do
          assign(socket, status: :empty, languages: [])
        else
          assign(socket, status: :ready, languages: languages)
        end

      {:error, _reason} ->
        assign(socket, status: :error, languages: [])
    end
  end

  defp check_tesseract do
    with :ok <- Quire.Ocr.Engine.check(),
         installed when is_list(installed) <- Image.OCR.Tessdata.installed_languages() do
      {:ok, installed}
    else
      {:error, _} = err -> err
      _ -> {:error, :unavailable}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_language_list(installed) do
    # Filter out internal/meta tessdata artefacts; keep only language codes.
    filtered =
      Enum.reject(installed, fn code ->
        String.starts_with?(code, "script/") or
          String.starts_with?(code, "configs/") or
          code in ~w(osd equ)
      end)

    available = if filtered == [], do: installed, else: filtered
    code_set = MapSet.new(available)

    # Present known languages first (sorted by label), then unknown codes
    known =
      @known_languages
      |> Enum.filter(fn {code, _label} -> code in code_set end)
      |> Enum.sort_by(fn {_code, label} -> label end)
      |> Enum.map(fn {code, label} -> %{code: code, label: label} end)

    unknown =
      available
      |> Enum.reject(&Map.has_key?(@known_languages, &1))
      |> Enum.sort()
      |> Enum.map(&%{code: &1, label: &1})

    known ++ unknown
  end

  defp load_defaults(socket) do
    user_id = socket.assigns[:user_id]

    settings =
      if user_id,
        do: Accounts.get_user_settings(user_id),
        else: %Quire.Accounts.UserSetting{}

    socket
    |> assign(
      selected_languages: split_lang(settings.ocr_default_lang || "eng"),
      output_mode: "skip",
      deskew: if(settings.ocr_auto_deskew == false, do: false, else: true),
      auto_rotate: if(settings.ocr_auto_rotate == false, do: false, else: true),
      clean: if(settings.ocr_clean == false, do: false, else: true),
      optimise_level: settings.ocr_optimise_level || 1
    )
  end

  defp split_lang(lang_str) when is_binary(lang_str) do
    lang_str |> String.split("+", trim: true) |> Enum.map(&String.trim/1)
  end

  defp split_lang(_), do: ["eng"]

  # ── Download-state helpers ──────────────────────────────────────────

  defp download_button_classes(lang, selected, states, errors) do
    cond do
      Map.get(states, lang) == :downloading ->
        "opacity-60 border-gray-300 dark:border-gray-600 text-gray-400 dark:text-gray-500"

      Map.has_key?(errors, lang) ->
        "border-red-300 dark:border-red-700 text-red-600 dark:text-red-400 bg-red-50 dark:bg-red-900/20"

      lang in selected ->
        "bg-accent/10 border-accent/30 text-accent font-medium cursor-pointer"

      true ->
        "border-chrome-border dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:border-gray-400 dark:hover:border-gray-500 cursor-pointer"
    end
  end

  defp ocr_can_run?(selected, states, errors, running) do
    not running and
      selected != [] and
      not has_download_errors?(selected, errors) and
      not has_downloading?(selected, states)
  end

  defp has_download_errors?(selected, errors) do
    Enum.any?(selected, &Map.has_key?(errors, &1))
  end

  defp has_downloading?(selected, states) do
    Enum.any?(selected, fn lang -> Map.get(states, lang) == :downloading end)
  end
end
