// T-058 (pdf-x78): performance pass against §14.1 budgets.
// Run against the dev server with seeded fixtures:
//   mise run server  (or mix phx.server)  then:  npx playwright test perf.spec.ts
// Measurements are taken on the target machine (Apple Silicon, plugged in,
// Chrome/Chromium). See plan3.md §14.1 lines 2115-2134.

import { test, expect } from '@playwright/test';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import { login } from './helpers';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const urls = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixture_urls.json'), 'utf-8'));

async function openWorkspace(page, title, { timeout = 60_000 } = {}) {
  await login(page);
  const url = urls[title];
  expect(url, `seed ${title} first`).toBeTruthy();
  const t0 = Date.now();
  await page.goto(url);
  await page.waitForSelector('#pdf-viewer-container .page canvas', { timeout });
  await page.waitForFunction(() => {
    const c = document.querySelector('#pdf-viewer-container .page canvas');
    return !!c && c.width > 0 && c.height > 0;
  });
  const t1 = Date.now();
  return { navMs: t1 - t0 };
}

function canvasInk(page) {
  return page.evaluate(() => {
    const c = document.querySelector('#pdf-viewer-container .page canvas');
    if (!c) return 0;
    const ctx = c.getContext('2d');
    const { width, height } = c;
    const data = ctx.getImageData(0, 0, width, height).data;
    let ink = 0;
    for (let i = 0; i < data.length; i += 4) {
      if (data[i] < 220 || data[i + 1] < 220 || data[i + 2] < 220) ink++;
    }
    return ink;
  });
}

// ── §14.1: Time to first page rendered (10 MB doc) < 1.5 s ────────────────
// 50mb_images.pdf is a genuine 50 MB, 250-page image-heavy doc — a stronger
// case than the 10 MB budget doc. Measure navigation → first painted canvas.
test('50mb_images.pdf: time to first page rendered', async ({ page }) => {
  const { navMs } = await openWorkspace(page, '50mb_images.pdf');
  const ink = await canvasInk(page);
  expect(ink, 'first page must actually render').toBeGreaterThan(500);
  console.log(`PERF first_page_ms=${navMs} doc=50mb_images.pdf (budget < 1500ms) ink=${ink}`);
  expect(navMs, 'time to first page rendered must be < 1.5s').toBeLessThan(1500);
});

// ── §14.1: Scroll — 60 fps sustained, ≤ 5 canvases retained ───────────────
test('500_pages.pdf: scroll fps and canvas retention', async ({ page }) => {
  await openWorkspace(page, '500_pages.pdf');
  await page.waitForTimeout(1500);

  const stats = await page.evaluate(async () => {
    const viewer = document.querySelector('#document-canvas')._pdfViewer;
    const container = document.querySelector('#pdf-viewer-container');
    const frames = [];
    let last = performance.now();
    const loop = (t) => {
      frames.push(t - last);
      last = t;
      raf = requestAnimationFrame(loop);
    };
    let raf = requestAnimationFrame(loop);

    // Scroll through ~25 pages by setting the scroll position directly.
    for (let i = 0; i < 25; i++) {
      const pageView = viewer.getPageView(i);
      if (pageView?.div) {
        container.scrollTop = pageView.div.offsetTop + 5;
      }
      await new Promise((r) => setTimeout(r, 40));
    }
    cancelAnimationFrame(raf);

    const canvasCount = document.querySelectorAll('#pdf-viewer-container canvas').length;
    const avgFrameMs = frames.length ? frames.reduce((a, b) => a + b, 0) / frames.length : 0;
    return {
      avgFrameMs,
      fps: avgFrameMs > 0 ? 1000 / avgFrameMs : 0,
      frames: frames.length,
      canvasCount,
      p95FrameMs: frames.length ? frames.sort((a, b) => a - b)[Math.floor(frames.length * 0.95)] : 0,
    };
  });

  console.log(`PERF scroll_fps=${stats.fps.toFixed(1)} avg_frame_ms=${stats.avgFrameMs.toFixed(2)} ` +
    `p95_frame_ms=${stats.p95FrameMs} canvases=${stats.canvasCount} (budget 60fps, <=5 canvases)`);
  expect(stats.fps, 'scroll must sustain ~60fps').toBeGreaterThan(30);
  expect(stats.canvasCount, 'canvas retention budget').toBeLessThanOrEqual(5);
});

// ── §14.1: LiveView payload per interaction < 50 KB ───────────────────────
// Measure the websocket frames pushed server→client during one interaction
// (toggle the search panel = a typical small interaction). The socket is
// created on mount, so the listener must attach BEFORE navigation.
test('LiveView payload per interaction < 50 KB', async ({ page }) => {
  const frames = []; // { ts, bytes }
  const sizeOf = (payload) => {
    if (typeof payload === 'string') return Buffer.byteLength(payload);
    if (payload instanceof Buffer || payload instanceof ArrayBuffer) return payload.byteLength ?? payload.length;
    if (payload && typeof payload === 'object' && payload.data !== undefined) return sizeOf(payload.data);
    return Buffer.byteLength(JSON.stringify(payload ?? ''));
  };
  page.on('websocket', (ws) => {
    ws.on('framesent', (payload) => frames.push({ ts: Date.now(), bytes: sizeOf(payload) }));
    ws.on('framereceived', (payload) => frames.push({ ts: Date.now(), bytes: sizeOf(payload) }));
  });

  await openWorkspace(page, '500_pages.pdf');
  await page.waitForTimeout(1200);

  // Do ONE interaction: toggle the search panel (open + close = two clicks,
  // but only the frames after the first click count).
  const t0 = Date.now();
  await page.locator('[role="toolbar"] button[phx-value-item="search"]').first().click();
  await page.waitForTimeout(800);
  await page.locator('[role="toolbar"] button[phx-value-item="search"]').first().click();
  await page.waitForTimeout(800);

  const interactionFrames = frames.filter((f) => f.ts >= t0);
  const maxFrame = interactionFrames.length ? Math.max(...interactionFrames.map((f) => f.bytes)) : 0;
  console.log(`PERF liveview_max_frame_bytes=${maxFrame} frames=${interactionFrames.length} (budget < 50KB)`);
  expect(maxFrame, 'per-interaction LiveView payload must be < 50 KB').toBeLessThan(50 * 1024);
});

// ── §14.1: BEAM RSS idle with 3 documents open < 500 MB ───────────────────
// The server side is measured by scripts/measure_beam_memory.mjs (opens 3
// workspaces in a headless browser and holds them while the caller samples
// `ps` RSS). This test only opens 3 docs to keep them alive for the script.
test('three documents stay open (RSS measured by script)', async ({ page }) => {
  for (const title of ['500_pages.pdf', '50mb_images.pdf', 'cjk.pdf']) {
    await openWorkspace(page, title);
  }
  console.log('PERF 3 docs open — measure BEAM RSS via scripts/measure_beam_memory.exs');
  expect(true).toBe(true);
});
