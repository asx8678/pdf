# ADR 0006 — Font pipeline: bundling, subsetting, shaping, and licensing

- **Status:** accepted
- **Date:** 2026-07-29
- **Tasks:** pdf-8d7 (decision). T-084, T-090/T-091 and T-157 own the
  dependent features; see Consequences.
- **Spec:** plan3.md §3.3, §9.2, §9.5, §9.11

## Context

Four features need server-side font bytes selected, embedded and (for CJK)
subset. No module in §3.3 currently owns font resources:

- **PDF/A** (§9.2) must "verify/embed fonts" (plan3.md:1745).
- **Stamping** (§9.5) — page numbers, watermarks, headers/footers, Bates —
  all take a font and are rendered by `Compose` + PDFium page objects.
- **Edit mode** (§9.5, T-091) creates new text runs via `Compose` and must
  embed the chosen font.
- **Translate** (§9.11, T-157) inserts new text runs via `Compose` into
  documents whose original fonts are unlikely to cover the target language.

§3.3 currently assigns the work to nobody. This ADR resolves who owns font
resources and how they are handled across the pipeline.

### The Standard 14

PDF's "Standard 14" fonts (Times Roman, Helvetica, Courier and their bold/
italic variants plus Symbol and ZapfDingbats) are guaranteed to exist in
every conforming reader. A content stream that references one needs no
embedding. Any additional font used by `Compose` — whether bundled with the
application or uploaded by a user — MUST be embedded in the output PDF.

### Available permissively-licensed fonts

| Family | Licence | Coverage | Standard-14 metric match |
|---|---|---|---|
| Liberation Sans / Serif / Mono | SIL OFL 1.1 | Latin, Cyrillic, Greek | Arial, Times New Roman, Courier New |
| DejaVu Sans / Serif / Mono | Bitstream Vera + public domain | Latin, Cyrillic, Greek, many others | None (wider x-height) |
| Noto Sans / Noto Serif | SIL OFL 1.1 | Very wide (Latin, CJK, Arabic, Devanagari, etc.) | None |
| Source Han Sans / Serif | SIL OFL 1.1 | CJK (separate region-specific OTFs) | None — CJK only |

All are permissive enough for embedding into redistributed PDFs with no
copyleft obligation on the document.

### Subsetting

A full CJK OTF is typically 15–30 MB. Embedding the whole font for a single
page stamp would balloon every stamped document. Subsetting — keeping only
the glyphs actually used — is essential for CJK and good practice for any
non-Standard-14 font.

PDFium's font API (`FPDFText_LoadFont`, `FPDFPage_InsertObject`) does NOT
subset. Neither does `lopdf`. Subsetting must be done by a separate library
before the font bytes are handed to PDFium or `Compose`.

### Shaping

Complex scripts — Arabic (cursive joining), Devanagari (re-ordering,
ligation), Thai (mark positioning), Khmer, etc. — require a shaping engine
(HarfBuzz) to produce correct glyph sequences from a Unicode string.
PDFium's own text API does NOT shape; it maps codepoints to glyph IDs
directly via the font's `cmap`, which produces incorrect output for complex
scripts.

No existing Hex dependency (nor the vix-bundled copy of HarfBuzz) exposes a
usable shaping API from Elixir. Writing or wrapping a shaping call is
feasible (HarfBuzz has a C API callable via NIF or `:crypto`-style NIF) but
represents a significant integration task with its own quality gate.

### Uploaded fonts

Users may upload custom TTF/OTF files through the format bar's "uploaded"
category (§9.5). These must be:
- Stored via `Storage.Ref` for persistence.
- Scanned for licence metadata (name, embedding permissions from the
  `OS/2` table's `fsType` field).
- Rejected at upload if the `fsType` bits forbid embedding (bit 2 or 3 set),
  or if parsing fails.
- Cached per-user to avoid re-upload on every session.

## Decision

### 1. Font ownership — `Quire.Compose.Font`

**A new module `Quire.Compose.Font` owns all font resources.** It is the
single module that knows which fonts are bundled, how to load and subset them,
and how to embed the result. `Quire.Compose` calls `Compose.Font` to resolve
a font family string to embedded font bytes; PDF/A calls it to verify
embedding. The `lopdf` document remains the storage for the resulting font
objects inside the PDF.

### 2. Bundled fonts — Liberation family (SIL OFL)

**Ship Liberation Sans / Serif / Mono.** They are:
- Metrically compatible with Arial / Times New Roman / Courier New, which
  means a document that uses the Standard-14 names with Liberation metrics
  re-renders identically whether the reader substitutes its own Standard 14
  or uses the embedded Liberation subset.
- SIL OFL — permissive, embedding is explicitly allowed.
- Small (~300 KB per weight) — six weights × three families fits under 6 MB.
- Cover Latin, Cyrillic, and Greek, which covers §9.5 stamping and most of
  the `Compose` use cases.

**CJK is deferred to T-157 (Translate).** Adding a CJK font (~15–30 MB for
a single weight) is not justified before a feature that actually needs it.
When T-157 lands, it will add Noto Sans CJK (or an equivalent SIL OFL font)
and the necessary subsetting pass. Until then `Compose.Font` returns
`{:error, :unsupported_script}` for any string whose Unicode script
properties are Han, Hangul, or Katakana/Hiragana.

### 3. Subsetting — pure-Elixir via `subset` bit

**Use the `subset` bit in the font's `OS/2` table (`fsType`) to mark the
font as subset when embedding.** The subsetting implementation itself is a
pure-Elixir TTF/OTF re-encoder that copies only:
- The `head`, `hhea`, `hmtx`, `maxp`, `os2`, `post`, `name`, `cmap` tables
  (required for a valid font).
- A stripped `glyf` / `CFF` table containing only the glyphs used.
- The `loca` table re-indexed to the stripped glyphs.

This is a small amount of Elixir code (~300 lines) that lives in
`Compose.Font.Subset` and needs no NIF. It handles the common case: simple
TTF and CFF-based OpenType fonts with < 256 glyphs after subsetting. Full
CFF2/COLR/svg table support is explicitly **out of scope** — fonts with
those tables will embed the full font with a warning.

**Why pure Elixir and not a Hex package:** The existing Hex font‑subset
packages (`ex_fontsubset`, `ttx`) are unmaintained (latest push 2018), have
no CI, and carry no guarantees for the edge cases Compose encounters. Writing
our own against the TTF spec is safer than depending on a frozen library.

### 4. Shaping — refused with a clear message

**Complex‑script shaping is refused.** `Compose.Font` returns
`{:error, :unsupported_script}` for any Unicode string whose dominant script
falls outside the supported set:

| Script family | Supported | Notes |
|---|---|---|
| Latin, Cyrillic, Greek | ✅ Bundled Liberation covers these | |
| CJK (Han, Hangul, Kana) | ✅ With full-font embed (subset planned for T-157) | Requires the user to have a CJK font available (bundled in T-157) |
| Arabic, Hebrew | ❌ Refused | Shaping required |
| Indic (Devanagari, Bengali, etc.) | ❌ Refused | Shaping required |
| Thai, Khmer, Lao | ❌ Refused | Shaping required |
| Other | ❌ Refused | Falls back to the error path |

The refusal message reads: *"The current font does not support this script.
Complex‑script text will appear as blank or incorrect glyphs. [Learn more]"*
linking to a doc page explaining the limitation. This matches T-091's
existing refusal language (§9.5).

A future HarfBuzz integration (T‑189 follow‑up or a dedicated shaping task)
can broaden the supported‑script list without changing the API surface of
`Compose.Font`.

### 5. Uploaded fonts — Storage.Ref + fsType check

- Uploaded TTF/OTF files are stored via `Storage.put/2` and the resulting
  `Ref` persisted on the user's `user_settings` row.
- `Compose.Font.Uploaded.parse/1` reads the `OS/2` table's `fsType` field.
  If bits 2 or 4 are set (`Restricted License embedding` / `Preview & Print
  embedding`), the upload is rejected with `{:error, :embedding_not_permitted}`.
- The font is cached in an ETS table (`user_fonts`) per user session; the
  ETS table is populated on login from the stored `Ref`s and evicted on
  logout.
- Only TTF and OTF (CFF‑based) are accepted. WOFF/WOFF2 are converted to
  TTF server‑side after upload.

## Consequences

### Positive

1. **Clear ownership.** `Compose.Font` is the single module responsible for
   font resolution, subsetting, and embedding. Dependent features (T-091,
   T-157, T-084) all call the same API.

2. **No surprise complexity.** Refusing complex scripts explicitly avoids a
   months‑long shaping integration without blocking stamping, watermark,
   page‑number, or Latin‑text features.

3. **Small binary footprint.** Liberation fonts add ~6 MB to the release.
   CJK is deferred until there is a feature that requires it.

4. **Licence safety.** The `OS/2` fsType scan on upload prevents embedding
   fonts whose licence forbids it, and the Liberation family's SIL OFL
   permits unrestricted embedding.

### Negative

1. **CJK users cannot stamp in their own language until T-157.** Mitigation:
   the client‑side pdf.js viewer can already render CJK using its own
   bundled `standard_fonts/`, so the viewing path is unaffected. Only the
   server‑side stamping path is blocked.

2. **Custom subsetter is new code.** The TTF re-encoder must be written and
   tested against the fixture corpus. Estimate ~300 lines plus tests; same
   order as a small Hex integration and safer than depending on an unmaintained
   library.

3. **Translation (T-157) cannot target complex scripts.** The overlay/sidecar/
   replace modes in §9.11 are limited to Latin/Cyrillic/Greek CJK until
   shaping lands. This is documented in T-157's spec.

### Actions required

- **plan3.md §3.3:** Add a row for `Compose.Font` — "Font resource management:
  bundling, loading, subsetting, embedding. Pure Elixir over `Quire.Pdf` for
  embedding and binary TTF/OTF parsing for subsetting. Complex scripts:
  refused with clear message."
- **plan3.md §9.5: line 1615:** Change "uploaded" to "uploaded (TTF/OTF only,
  embedding check on upload)".
- **plan3.md §9.11:** Add a note that T-157's output is limited to
  Latin/Cyrillic/Greek until shaping integration lands.
- **T-084 (PDF/A):** Re-scope to add `Compose.Font.verify_embedding/1` as
  the canonical check. Remove font-embedding from PDF/A's spec — PDF/A calls
  `Compose.Font`, it does not own font logic.
- **T-091 (edit mode):** Already references "refuse gracefully" for
  non-embedded fonts — no change needed beyond using `Compose.Font`.
- **T-157 (Translate):** Document the Latin-only output limitation and point
  to this ADR.
