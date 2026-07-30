import { test, expect } from '@playwright/test';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Load Elixir fixture (pre-computed by scripts/generate_geometry_fixture.exs)
const fixturePath = path.resolve(__dirname, '../fixtures/geometry_differential_fixture.json');
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf-8'));
const tuples = fixture.tuples as Array<{
  pw: number; ph: number; css_x: number; css_y: number;
  css_w: number; css_h: number; rot: number;
  pdf_x: number; pdf_y: number; pdf_w: number; pdf_h: number;
}>;

// Load geometry.js as text
const geometryPath = path.resolve(__dirname, '../../assets/js/pdf/geometry.js');
const geometrySource = fs.readFileSync(geometryPath, 'utf-8');

// Strip ESM exports so they become globals for page.evaluate access
const geometryScript = geometrySource
  .replace(/^export function /gm, 'function ')
  .replace(/^export /gm, '')
  .replace(/^const /gm, 'var ')
  .replace(/^let /gm, 'var ');

test('JS cssToPdfRotated agrees with pre-computed Elixir on 1000 random tuples', async ({ page }) => {
  await page.goto('about:blank');
  await page.addScriptTag({ content: geometryScript });

  // Pass the fixture data to page context and evaluate each tuple
  const mismatches = await page.evaluate((data) => {
    const failures: string[] = [];
    for (const t of data) {
      // Run JS cssToPdfRotated
      const js = cssToPdfRotated(t.css_x, t.css_y, t.css_w, t.css_h, t.pw, t.ph, t.rot);
      const dx = Math.abs(js.x - t.pdf_x);
      const dy = Math.abs(js.y - t.pdf_y);
      const dw = Math.abs(js.width - t.pdf_w);
      const dh = Math.abs(js.height - t.pdf_h);
      if (dx > 0.01 || dy > 0.01 || dw > 0.01 || dh > 0.01) {
        failures.push(
          `Tuple #${failures.length}: css=(${t.css_x},${t.css_y}) ${t.css_w}x${t.css_h} ` +
          `pw=${t.pw} ph=${t.ph} rot=${t.rot}: ` +
          `JS (${js.x.toFixed(2)},${js.y.toFixed(2)}) vs ` +
          `Elixir (${t.pdf_x.toFixed(2)},${t.pdf_y.toFixed(2)})`
        );
        if (failures.length >= 5) break;
      }
    }
    return failures;
  }, tuples);

  expect(mismatches.length).toBe(0);
});

test('deliberately broken implementation is caught by the suite', async ({ page }) => {
  await page.goto('about:blank');
  await page.addScriptTag({ content: `
    function brokenRoundTripOk(x, y, w, h, pw, ph, rot) {
      var d = ((rot % 360) + 360) % 360;
      var px, py;
      switch (d) {
        case 90:  px = pw + y;  py = -x - h + 1; break;
        case 180: px = pw - x;  py = ph - y - h; break;
        case 270: px = y + 1;   py = ph - x - h; break;
        default:  px = x;       py = ph - y - h;
      }
      var cx, cy;
      switch (d) {
        case 90:  cx = -py - h;    cy = px - pw; break;
        case 180: cx = pw - px;    cy = ph - py - h; break;
        case 270: cx = ph - py - h; cy = px; break;
        default:  cx = px;         cy = ph - py - h;
      }
      return Math.abs(cx - x) <= 0.01 && Math.abs(cy - y) <= 0.01;
    }
    window.r1 = brokenRoundTripOk(10, 20, 100, 50, 612, 792, 90);
    window.r2 = brokenRoundTripOk(10, 20, 100, 50, 612, 792, 270);
    window.r3 = brokenRoundTripOk(10, 20, 100, 50, 612, 792, 0);
    window.r4 = brokenRoundTripOk(10, 20, 100, 50, 612, 792, 180);
  `});

  const r1 = await page.evaluate(() => window.r1);
  const r2 = await page.evaluate(() => window.r2);
  const r3 = await page.evaluate(() => window.r3);
  const r4 = await page.evaluate(() => window.r4);
  expect(!r1).toBe(true);
  expect(!r2).toBe(true);
  expect(r3).toBe(true);
  expect(r4).toBe(true);
});
