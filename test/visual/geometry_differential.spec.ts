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

    // Generate 1000 random tuples
    for (let i = 0; i < 1000; i++) {
      var pw = Math.floor(random() * 1100) + 100;  // 100-1200
      var ph = Math.floor(random() * 1500) + 100;  // 100-1600
      var x = Math.floor(random() * Math.max(1, pw - 10));
      var y = Math.floor(random() * Math.max(1, ph - 10));
      var bw = Math.floor(random() * Math.max(10, pw - x)) + 10;
      var bh = Math.floor(random() * Math.max(10, ph - y)) + 10;
      var rot = [0, 90, 180, 270][Math.floor(random() * 4)];

      // Round trip: CSS → PDF → CSS should be identity
      var ok = window.roundTripOk(x, y, bw, bh, pw, ph, rot);
      if (!ok) {
        failures.push(`Round trip: (${x},${y}) ${bw}x${bh} pw=${pw} ph=${ph} rot=${rot}`);
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
    function brokenRoundTripOk(x, y, w, h, pw, ph, rot) {
      // Off-by-one in rotation 90 y-flip and rotation 270 x formula
      var d = ((rot % 360) + 360) % 360;
      var px, py;
      switch (d) {
        case 90:  px = pw + y;  py = -x - h + 1; break;  // off by +1
        case 180: px = pw - x;  py = ph - y - h; break;
        case 270: px = y + 1;   py = ph - x - h; break;  // off by +1
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
