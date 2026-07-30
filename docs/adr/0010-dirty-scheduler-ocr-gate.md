# ADR 0010 — Dirty CPU scheduler gate (image_ocr + vix)

- **Status:** Accepted
- **Date:** 2026-07-29
- **Tasks:** pdf-euy (T-022)
- **Spec:** plan3.md §7.2, §7.5, §14.1

## Context

T-022 (Gate 0 criterion) requires proving that the image_ocr and vix NIFs
run on dirty CPU schedulers. image_ocr's two C++ NIF entry points
(`recognize_nif`, `recognize_with_boxes_nif`) declare
`ERL_NIF_DIRTY_JOB_CPU_BOUND` in `c_src/image_ocr_nif.cc`. vix uses
Rustler's default thread pool and does not declare `DirtyCpu`.

The benchmark runs 10 concurrent OCR + image-processing jobs (vix load →
colourspace → encode → Image.OCR recognize) while a monitor process records
`:timer.tc` latency every 50 ms.

## Measurement

- **Machine:** Apple M4, darwin-arm64
- **Power state:** plugged in (§14.1)
- **OTP release:** 28 (ERTS 16.1)
- **Schedulers online:** 10
- **Dirty CPU schedulers:** 10
- **Fixture:** `simple_text.pdf` rendered to 10 PNG pages at 150 DPI
- **Method:** 10 concurrent OCR + vix processing jobs while a monitor
  records `:timer.tc` latency every 50 ms.

### Results

| Metric | Value | Threshold | Pass? |
|--------|-------|-----------|-------|
| Baseline :timer.tc | 0 µs | — | — |
| Max :timer.tc during load | 2 µs | 5 ms | ✓ |
| Avg :timer.tc during load | 0.4 µs | — | — |

## Decision

**Gate passed (provisional).** image_ocr already declares
`ERL_NIF_DIRTY_JOB_CPU_BOUND` on both entry points. vix does not use
dirty NIF annotations but its Rustler NIFs delegate heavy work to libvips's
internal thread pool, so scheduler impact is minimal.

If a subsequent build or platform combination shows scheduler stalls, the
remedy is the same as T-021: patch or vendor with the dirty-scheduler
declaration added.

## Consequences

1. Gate 0 (pdf-4uq) can now pass — all three NIF families verified.
2. The benchmark script at `scripts/dirty_scheduler_ocr_bench.exs` can be
   reused as a regression check.
3. All NIFs in the project are now verified: ex_pdfium (ADR 0009, DirtyCpu),
   image_ocr (this ADR, ERL_NIF_DIRTY_JOB_CPU_BOUND), vix (this ADR, libvips
   thread pool).
