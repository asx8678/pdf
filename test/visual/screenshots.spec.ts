import { test } from '@playwright/test';
import path from 'path';
import { login } from './helpers';

const BASELINE_DIR = path.join(__dirname, 'darwin-arm64');

const WIDTHS = [1280, 1600, 1920];
const TABS = [
  'view',
  'create-convert',
  'fill-sign',
  'edit',
  'page',
  'comment',
  'secure',
  'forms',
  'esign',
  'ocr',
  'translate',
];

/** Helper to set up a page with viewport, colour scheme, and theme. */
async function preparePage(
  { page },
  width: number,
  mode: 'light' | 'dark',
) {
  await page.setViewportSize({ width, height: 900 });
  await page.addInitScript((theme) => {
    localStorage.setItem('phx:theme', theme);
  }, mode);
}

// ── Home page ───────────────────────────────────────────────────────────

for (const width of WIDTHS) {
  for (const mode of ['light', 'dark'] as const) {
    test(`home ${width}px ${mode}`, async ({ page }) => {
      await preparePage({ page }, width, mode);
      await page.goto('/');
      await page.waitForSelector('body');
      await page.emulateMedia({ colorScheme: mode });
      await page.waitForTimeout(500);
      await page.screenshot({
        path: path.join(BASELINE_DIR, `home-${width}px-${mode}.png`),
        fullPage: false,
      });
    });
  }
}

// ── Workspace (logged in) ───────────────────────────────────────────────

for (const width of WIDTHS) {
  for (const mode of ['light', 'dark'] as const) {
    test(`workspace ${width}px ${mode}`, async ({ page }) => {
      await preparePage({ page }, width, mode);
      await login(page);

      // Navigate to workspace
      await page.goto('/workspace/doc-1');
      await page.waitForSelector('#workspace-shell');
      await page.emulateMedia({ colorScheme: mode });
      await page.waitForTimeout(500);

      await page.screenshot({
        path: path.join(BASELINE_DIR, `workspace-${width}px-${mode}.png`),
        fullPage: false,
      });
    });
  }
}

// ── Workspace per-tab ───────────────────────────────────────────────────

for (const width of WIDTHS) {
  for (const mode of ['light', 'dark'] as const) {
    for (const tab of TABS) {
      test(`workspace ${tab} ${width}px ${mode}`, async ({ page }) => {
        await preparePage({ page }, width, mode);
        await login(page);

        await page.goto('/workspace/doc-1');
        await page.waitForSelector('#workspace-shell');
        await page.emulateMedia({ colorScheme: mode });
        await page.waitForTimeout(300);

        // Click the desired tab
        await page.click(`button[role="tab"][phx-value-tab="${tab}"]`);
        await page.waitForTimeout(300);

        await page.screenshot({
          path: path.join(BASELINE_DIR, `workspace-${tab}-${width}px-${mode}.png`),
          fullPage: false,
        });
      });
    }
  }
}
