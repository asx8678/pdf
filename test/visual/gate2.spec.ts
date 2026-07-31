import { test, expect } from '@playwright/test';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import { login } from './helpers';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Workspace paths seeded by scripts/seed_workspace_fixtures.exs.
// Run that script (against the dev DB) before `mise run e2e`.
const urls = JSON.parse(
  fs.readFileSync(path.join(__dirname, 'fixture_urls.json'), 'utf-8'),
);

async function openWorkspace(page: import('@playwright/test').Page, title: string) {
  await login(page);
  const url = urls[title];
  expect(url, `seed ${title} first (mix run scripts/seed_workspace_fixtures.exs)`).toBeTruthy();
  await page.goto(url);

  // pdf.js renders the first page into a canvas inside the viewer container.
  await page.waitForSelector('#pdf-viewer-container .page canvas', { timeout: 30_000 });
  await page.waitForFunction(() => {
    const c = document.querySelector('#pdf-viewer-container .page canvas');
    return !!c && c.width > 0 && c.height > 0;
  });
  // Let the render task finish drawing.
  await page.waitForTimeout(1200);
}

/** Count non-white pixels on the first page's canvas — a blank page fails. */
async function canvasInk(page: import('@playwright/test').Page) {
  return page.evaluate(() => {
    const c = document.querySelector('#pdf-viewer-container .page canvas') as HTMLCanvasElement;
    const ctx = c.getContext('2d')!;
    const { width, height } = c;
    const data = ctx.getImageData(0, 0, width, height).data;
    let ink = 0;
    for (let i = 0; i < data.length; i += 4) {
      // count pixels that are clearly not white/transparent
      if (data[i] < 220 || data[i + 1] < 220 || data[i + 2] < 220) ink++;
    }
    return { ink, pixels: (width * height) / 1 };
  });
}

/** Concatenated text-layer spans for the first page. */
async function textLayer(page: import('@playwright/test').Page) {
  return page.evaluate(() => {
    const spans = Array.from(document.querySelectorAll('#pdf-viewer-container .page .textLayer span'))
      .map((s) => (s as HTMLElement).textContent || '')
      .join('');
    return spans;
  });
}

// Gate 2 verify #2 — cjk.pdf and rtl_arabic.pdf render with correct glyphs
// and no blank pages (proving the vendored cmaps/fonts copy serves the
// embedded font subsets).
test('cjk.pdf renders glyphs and no blank page', async ({ page }) => {
  await openWorkspace(page, 'cjk.pdf');
  const { ink } = await canvasInk(page);
  expect(ink, 'CJK page must not be blank').toBeGreaterThan(200);
  const text = await textLayer(page);
  expect(text, 'text layer should carry CJK characters').toMatch(/[\u4e00-\u9fff]/);
});

test('rtl_arabic.pdf renders glyphs and no blank page', async ({ page }) => {
  await openWorkspace(page, 'rtl_arabic.pdf');
  const { ink } = await canvasInk(page);
  expect(ink, 'Arabic page must not be blank').toBeGreaterThan(200);
  const text = await textLayer(page);
  expect(text, 'text layer should carry Arabic characters').toMatch(/[\u0600-\u06ff]/);
});

// Gate 2 verify #3 — rotated_pages.pdf and cropped_nonzero_origin.pdf
// render correctly and clicks map to the right user-space points via the
// T-043 helpers (pdf.js PageViewport conversions — §14.3).
test('rotated_pages.pdf: click maps to user space through a 90° rotation', async ({ page }) => {
  await openWorkspace(page, 'rotated_pages.pdf');
  await page.evaluate(() => {
    (document.querySelector('#document-canvas') as any)._pdfViewer.currentPageNumber = 2;
  });
  await page.waitForTimeout(1500);

  const r = await page.evaluate(() => {
    const viewer = (document.querySelector('#document-canvas') as any)._pdfViewer;
    const pageView = viewer.getPageView(viewer.currentPageNumber - 1);
    const vp = pageView.viewport;
    // Click at 25% across / 50% down of the displayed (rotated) page.
    const vx = vp.width * 0.25;
    const vy = vp.height * 0.5;
    const [px, py] = vp.convertToPdfPoint(vx, vy);
    const [backX, backY] = vp.convertToViewportPoint(px, py);
    return { px, py, backX, backY, vx, vy, rot: vp.rotation, w: vp.width, h: vp.height };
  });

  expect(r.rot).toBe(90);
  // Round-trip: click -> pdf -> click must land back on the same viewport point.
  expect(Math.abs(r.backX - r.vx)).toBeLessThan(0.01);
  expect(Math.abs(r.backY - r.vy)).toBeLessThan(0.01);
  // The converted point must lie inside the 612x792 user-space page.
  expect(r.px).toBeGreaterThanOrEqual(0);
  expect(r.px).toBeLessThanOrEqual(612);
  expect(r.py).toBeGreaterThanOrEqual(0);
  expect(r.py).toBeLessThanOrEqual(792);
  // A rotated page displays landscape: viewport width > height.
  expect(r.w).toBeGreaterThan(r.h);
});

test('cropped_nonzero_origin.pdf: click mapping subtracts the CropBox origin', async ({ page }) => {
  await openWorkspace(page, 'cropped_nonzero_origin.pdf');

  const r = await page.evaluate(() => {
    const viewer = (document.querySelector('#document-canvas') as any)._pdfViewer;
    const pageView = viewer.getPageView(0);
    const vp = pageView.viewport;
    // MediaBox 612x792, CropBox [72 72 540 720] -> 468x648 in PDF space.
    // The displayed top-left corner must map to PDF (72, 720) — the crop
    // origin is subtracted from the click, proving the T-043 mapping.
    // (vp.width/vp.height are in viewport units = pdf points x scale, so
    // PDF-space extents come from the convertToPdfPoint corners.)
    const [px0, py0] = vp.convertToPdfPoint(0, 0);
    const [px1, py1] = vp.convertToPdfPoint(vp.width, vp.height);
    const [midX, midY] = vp.convertToPdfPoint(vp.width / 2, vp.height / 2);
    return { px0, py0, px1, py1, midX, midY };
  });

  // Display top-left -> PDF top-left of the crop (72, 720).
  expect(r.px0).toBeCloseTo(72, 0);
  expect(r.py0).toBeCloseTo(720, 0);
  // Display bottom-right -> PDF bottom-right of the crop (540, 72).
  expect(r.px1).toBeCloseTo(540, 0);
  expect(r.py1).toBeCloseTo(72, 0);
  // PDF-space extents equal the CropBox size (468x648).
  expect(r.px1 - r.px0).toBeCloseTo(468, 0);
  expect(r.py0 - r.py1).toBeCloseTo(648, 0);
  // Page centre maps inside the crop.
  expect(r.midX).toBeGreaterThan(72);
  expect(r.midX).toBeLessThan(540);
  expect(r.midY).toBeGreaterThan(72);
  expect(r.midY).toBeLessThan(720);
});

// Gate 2 verify #5 (browser half) — the PDFFindController path on
// 500_pages.pdf finds the same pages the server fallback finds.
// The server side is asserted in test/quire/gate2_search_equality_test.exs;
// here we confirm the real client path agrees with the fixture content.
// PDFFindController is a plain SUBSTRING matcher: "Page 5" hits pages
// 5, 50..59 and 500 (12 pages) — the literal substring "Page 5" is absent
// from "Page 15". The server fallback scan (Quire.Search) uses identical
// substring semantics and returns the same 12 pages.
test('500_pages.pdf: PDFFindController path finds the expected pages', async ({ page }) => {
  await openWorkspace(page, '500_pages.pdf');

  // Open the search panel via the right rail's Search button.
  const railBtn = page.locator('[role="toolbar"] button[phx-value-item="search"]').first();
  await railBtn.click();
  await page.waitForSelector('#search-panel input:visible', { timeout: 10_000 });

  const input = page.locator('#search-panel input[type="text"]');
  await input.fill('Page 5');
  await input.press('Enter');

  // Wait for the results counter to settle.
  await page.waitForFunction(() => {
    const el = document.querySelector('#search-panel [aria-live="polite"]');
    return el && /results/.test(el.textContent || '');
  }, undefined, { timeout: 20_000 });

  const countText = await page.evaluate(() => {
    const el = document.querySelector('#search-panel [aria-live="polite"]');
    return (el as HTMLElement).textContent || '';
  });
  const match = countText.match(/(\d+)\s+of\s+(\d+)\s+results/);
  expect(match, `result counter text: "${countText}"`).toBeTruthy();
  const shown = parseInt(match![1], 10);
  const total = parseInt(match![2], 10);

  // Pages whose label contains the literal substring "Page 5":
  // 5, 50..59 and 500 — 12 pages (substring, not digit-presence).
  const expected = 12;
  expect(total).toBe(expected);
  expect(shown).toBe(1);

  // The panel shows a row for the first hit (page 5) via the streamed list.
  await page.waitForSelector('#search-results button', { timeout: 10_000 });
});
