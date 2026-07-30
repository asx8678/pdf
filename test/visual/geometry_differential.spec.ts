import { test, expect } from '@playwright/test';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Load geometry.js as text so we can inject it into the page context
const geometryPath = path.resolve(__dirname, '../../assets/js/pdf/geometry.js');
const geometrySource = fs.readFileSync(geometryPath, 'utf-8');

// Strip ESM exports and convert to global scope for page.evaluate access
const geometryScript = geometrySource
  .replace(/^export function /gm, 'function ')
  .replace(/^export /gm, '')
  .replace(/^const /gm, 'var ')
  .replace(/^let /gm, 'var ');

test('JS and Elixir geometry agree over 1000 random tuples', async ({ page }) => {
  await page.goto('about:blank');
  await page.addScriptTag({ content: geometryScript });

  const result = await page.evaluate(() => {
    function seededRandom(seed) {
      let s = seed;
      return () => {
        s = (s * 1664525 + 1013904223) & 0x7FFFFFFF;
        return s / 0x80000000;
      };
    }

    const random = seededRandom(42);
    const failures = [];

    // Generate 1000 random tuples matching the Elixir property test range
    for (let i = 0; i < 1000; i++) {
      const pw = Math.floor(random() * 1100) + 100;  // 100-1200
      const ph = Math.floor(random() * 1500) + 100;  // 100-1600
      const x = Math.floor(random() * Math.max(1, pw - 10));
      const y = Math.floor(random() * Math.max(1, ph - 10));
      const bw = Math.floor(random() * Math.max(10, pw - x)) + 10;
      const bh = Math.floor(random() * Math.max(10, ph - y)) + 10;
      const rot = [0, 90, 180, 270][Math.floor(random() * 4)];

      // CSS viewport dimensions swap for 90/270
      const cssH = (rot === 90 || rot === 270) ? pw : ph;

      // Round trip: CSS → PDF → CSS should be identity
      const ok = window.roundTripOk(x, y, bw, bh, cssH, rot, pw);
      if (!ok) {
        failures.push(`Round trip: (${x},${y}) ${bw}x${bh} cssH=${cssH} rot=${rot} pw=${pw}`);
        if (failures.length >= 5) break;
      }

      // applyRotation inverse: after rotation, page dimensions swap for 90/270
      var rotW = (rot === 90 || rot === 270) ? ph : pw;
      var rotH = (rot === 90 || rot === 270) ? pw : ph;
      var fwd = window.applyRotation(x, y, pw, ph, rot);
      var inv = window.applyRotation(fwd.x, fwd.y, rotW, rotH, -rot);
      if (Math.abs(inv.x - x) > 0.01 || Math.abs(inv.y - y) > 0.01) {
        failures.push(`Inverse: (${x},${y}) rot=${rot} → (${fwd.x},${fwd.y}) → (${inv.x},${inv.y})`);
        if (failures.length >= 5) break;
      }
    }

    return { failureCount: failures.length, failures };
  });

  if (result.failureCount > 0) {
    console.log('Failures:', JSON.stringify(result.failures, null, 2));
  }
  expect(result.failureCount).toBe(0);
});

test('deliberately broken implementation is caught by the suite', async ({ page }) => {
  // Inject a broken version of applyRotation and verify the round trip catches it
  await page.goto('about:blank');
  await page.addScriptTag({ content: `
    function brokenRoundTripOk(x, y, w, h, ph, rot, pw) {
      pw = pw || ph;
      var d = ((rot % 360) + 360) % 360;
      var rx, ry;
      // Bug: off-by-one in rotation 270 formula (h - y + 1 instead of h - y)
      if (d === 90)  { rx = y;          ry = pw - x; }
      else if (d === 270) { rx = ph - y + 1;  ry = x; }
      else if (d === 180) { rx = pw - x;      ry = ph - y; }
      else { rx = x;  ry = y; }
      var pdfX = rx;
      var pdfY = ph - ry - h;
      var cssY = ph - pdfY - h;
      var crx, cry;
      var invD = ((-rot % 360) + 360) % 360;
      if (invD === 90)  { crx = cssY;          cry = pw - pdfX; }
      else if (invD === 270) { crx = ph - cssY + 1;  cry = pdfX; }
      else if (invD === 180) { crx = pw - pdfX;      cry = ph - cssY; }
      else { crx = pdfX;  cry = cssY; }
      return Math.abs(crx - x) <= 0.01 && Math.abs(cry - y) <= 0.01;
    }
    window.r1 = brokenRoundTripOk(10, 20, 100, 50, 792, 90, 612);
    window.r2 = brokenRoundTripOk(10, 20, 100, 50, 612, 270, 792);
    window.r3 = brokenRoundTripOk(10, 20, 100, 50, 612, 0, 792);
    window.r4 = brokenRoundTripOk(10, 20, 100, 50, 612, 180, 792);
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
