defmodule Quire.SearchRedact do
  @moduledoc """
  **Search and redact with presets and per-hit review** (plan3.md §9.7
  line 1681, T-135).

  Two-stage flow:

  1. **Search** — run a literal or regex query across the whole document,
     or one of the five built-in presets (SSN, credit card, email, phone,
     IBAN). Each hit carries the page, the exact matched text, a snippet of
     surrounding context, and the user-space rect(s) covering the match so
     the redaction engine can act on it.

  2. **Apply** — the caller selects individual hits (per-hit accept/reject)
     and passes the accepted hits to `marks_for_hits/1`, which converts them
     to T-134 redaction marks (`%{page, rect}`). The actual destructive
     removal happens through `Quire.Documents.redact_document/3` /
     `Quire.Workers.SecureWorker`, including the mandatory post-hoc
     verification (R-06).

  Search is built on `Quire.Render.extract_text/2` spans (text + bounds per
  page), so it works server-side on any document the render engine can read
  — no client-side pdf.js dependency — and a 500-page document can be
  searched in a background task without blocking the LiveView.
  """

  alias Quire.Render
  alias Quire.Storage.Ref

  @type hit :: %{
          required(:id) => String.t(),
          required(:page) => non_neg_integer(),
          required(:text) => String.t(),
          required(:rect) => [number()],
          required(:snippet) => String.t()
        }

  @typedoc "A T-134 redaction mark: zero-based page + user-space rect."
  @type mark :: %{required(:page) => non_neg_integer(), required(:rect) => [number()]}

  # ── Presets ──────────────────────────────────────────────────────────────

  @doc """
  The five built-in preset detectors: name → human label + regex.

  Every preset is anchored on word boundaries where that is meaningful so a
  search for "SSN" does not also flag "xSSNy" inside a longer token. The
  regexes are deliberately conservative (see tests for known-positive /
  known-negative strings):

    * `:ssn`      — `###-##-####`
    * `:card`     — 13–16 digit payment-card number (Luhn-valid candidates)
    * `:email`    — RFC-ish local@domain with a dotted TLD
    * `:phone`    — North-American-style `+1 (555) 123-4567` and variants
    * `:iban`     — ISO 13616 IBAN (`[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}`)
  """
  @spec presets() :: [{atom(), String.t(), Regex.t()}]
  def presets do
    [
      {:ssn, "Social Security Number", ~r/(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)/},
      {:card, "Credit / debit card", ~r/(?<!\d)(?:\d{4}[-\s]?){3}\d{4}(?!\d)/},
      {:email, "Email address", ~r/\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b/},
      {:phone, "Phone number", ~r/(?:\+?1[\s\-.]?)?\(?\d{3}\)?[\s\-.]?\d{3}[\s\-.]?\d{4}(?!\d)/},
      {:iban, "IBAN", ~r/\b[A-Z]{2}\d{2}(?:[ \-]?[A-Z0-9]){11,30}\b/}
    ]
  end

  @doc "Returns the label for a preset name (or `nil`)."
  @spec preset_label(atom() | String.t()) :: String.t() | nil
  def preset_label(preset) do
    Enum.find_value(presets(), fn {name, label, _regex} ->
      if to_string(name) == to_string(preset), do: label
    end)
  end

  @doc "Returns the compiled regex for a preset name (or `nil`)."
  @spec preset_regex(atom() | String.t()) :: Regex.t() | nil
  def preset_regex(preset) do
    Enum.find_value(presets(), fn {name, _label, regex} ->
      if to_string(name) == to_string(preset), do: regex
    end)
  end

  # ── Search ───────────────────────────────────────────────────────────────

  @doc """
  Search `ref` for `query`.

  `query` is treated as a **literal** string by default; pass
  `regex: true` to interpret it as a regular expression. Returns
  `{:ok, [hit()]}` or `{:error, reason}`.

  Each hit's `:rect` is a user-space `[x0, y0, x1, y1]` bounding box
  covering the matched text (the union of the span rects it overlaps).
  """
  @spec search(Ref.t(), String.t(), keyword()) :: {:ok, [hit()]} | {:error, term()}
  def search(%Ref{} = ref, query, opts \\ []) when is_binary(query) do
    regex? = Keyword.get(opts, :regex, false)

    if String.trim(query) == "" do
      {:ok, []}
    else
      case compile_query(query, regex?) do
        {:ok, pattern} ->
          with {:ok, pages} <- Render.extract_text(ref) do
            hits =
              pages
              |> Enum.flat_map(fn %{page: page, spans: spans} ->
                spans_for_page(page, spans, pattern)
              end)

            {:ok, hits}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Run a built-in preset search.

  Returns `{:ok, [hit()]}` where each hit is tagged with the preset name.
  """
  @spec search_preset(Ref.t(), atom() | String.t()) :: {:ok, [hit()]} | {:error, term()}
  def search_preset(%Ref{} = ref, preset) do
    case preset_regex(preset) do
      nil ->
        {:error, :unknown_preset}

      regex ->
        with {:ok, hits} <- search(ref, Regex.source(regex), regex: true) do
          {:ok, Enum.map(hits, &Map.put(&1, :preset, to_string(preset)))}
        end
    end
  end

  # ── Marks ────────────────────────────────────────────────────────────────

  @doc """
  Convert a list of accepted hits into T-134 redaction marks.

  Each accepted hit may be either the full `hit()` map (from `search/3`) or
  a `%{"id" => ...}` reference into `all_hits` (from the LiveView's
  checkbox payload). Marks are deduplicated by `{page, rect}` so accepting
  overlapping hits never redacts the same area twice.
  """
  @spec marks_for_hits([hit()] | [map()], [hit()] | nil) :: [mark()]
  def marks_for_hits(accepted, all_hits \\ nil)

  def marks_for_hits(accepted, all_hits) when is_list(accepted) do
    hits =
      if is_list(all_hits) do
        all_hits
      else
        accepted
      end

    by_id = Map.new(hits, &{&1[:id], &1})

    accepted
    |> Enum.flat_map(fn
      %{page: page, rect: rect} when is_integer(page) and is_list(rect) ->
        [%{page: page, rect: rect}]

      %{"page" => page, "rect" => rect} when is_integer(page) and is_list(rect) ->
        [%{page: page, rect: rect}]

      %{"id" => id} ->
        case Map.get(by_id, id) do
          %{page: page, rect: rect} -> [%{page: page, rect: rect}]
          _ -> []
        end

      %{id: id} ->
        case Map.get(by_id, id) do
          %{page: page, rect: rect} -> [%{page: page, rect: rect}]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(&{&1.page, &1.rect})
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp compile_query(query, true) do
    case Regex.compile(query) do
      {:ok, regex} -> {:ok, regex}
      {:error, reason} -> {:error, {:invalid_regex, inspect(reason)}}
    end
  rescue
    e in Regex.CompileError -> {:error, {:invalid_regex, e.message}}
  end

  defp compile_query(query, false) do
    {:ok, Regex.compile!(Regex.escape(query))}
  end

  # Find every match of `pattern` in the page's text, mapping each match
  # back onto the span(s) it overlaps and computing a combined rect.
  defp spans_for_page(page, spans, pattern) do
    # Build the full page text with per-character span attribution so a
    # match that crosses a span boundary still gets an accurate rect.
    {chars, _} =
      Enum.reduce(spans, {[], []}, fn span, {chars_acc, _seen} ->
        text = span.text || ""
        bounds = span.bounds

        span_chars =
          text
          |> String.graphemes()
          |> Enum.map(fn g -> {g, bounds} end)

        {chars_acc ++ span_chars, nil}
      end)

    full_text = chars |> Enum.map(&elem(&1, 0)) |> Enum.join("")

    case Regex.scan(pattern, full_text, return: :index) do
      [] ->
        []

      matches ->
        matches
        |> Enum.with_index()
        |> Enum.map(fn {[{match_start, match_len} | _], index} ->
          matched = binary_part(full_text, match_start, match_len)
          rect = rect_for_range(chars, match_start, match_len)
          snippet = snippet_for(full_text, match_start, match_len)

          %{
            id: "srh-#{page}-#{index}",
            page: page,
            text: matched,
            rect: rect,
            snippet: snippet
          }
        end)
    end
  end

  # Compute the union rect (user space, bottom-left origin) of the chars
  # covering `[start, start + len)` in the grapheme list.
  defp rect_for_range(chars, start, len) do
    in_range =
      chars
      |> Enum.slice(start, len)
      |> Enum.map(&elem(&1, 1))
      |> Enum.reject(&is_nil/1)

    case in_range do
      [] ->
        [0, 0, 0, 0]

      bounds_list ->
        left = bounds_list |> Enum.map(& &1.left) |> Enum.min()
        right = bounds_list |> Enum.map(& &1.right) |> Enum.max()
        bottom = bounds_list |> Enum.map(& &1.bottom) |> Enum.min()
        top = bounds_list |> Enum.map(& &1.top) |> Enum.max()
        [left, bottom, right, top]
    end
  end

  # ~40 characters of context around the match, with the match itself kept
  # whole at the front.
  defp snippet_for(text, start, len) do
    ctx_before = 25
    ctx_after = 40

    s = max(start - ctx_before, 0)
    e = min(start + len + ctx_after, byte_size(text))

    binary_part(text, s, e - s)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
