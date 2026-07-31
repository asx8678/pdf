import { test, expect } from '@playwright/test';
import { login } from './helpers';

// T-079 Clipboard to PDF: client-side navigator.clipboard.read() → text or
// image → @cantoo/pdf-lib page → upload as revision 1 → workspace.
//
// Runs against the dev server (localhost:4000) with the seeded user; see
// helpers.ts for the login flow. Headless Chromium supports the async
// Clipboard API when clipboard-read/clipboard-write permissions are granted
// on the context; the denial path stubs read() to reject deterministically.

const CREATE_CONVERT_TAB = 'button[role="tab"][phx-value-tab="create-convert"]';
const CLIPBOARD_BTN = 'button[id="clipboard-pdf-btn"]';
const PASTE_TARGET = 'div[id="clipboard-paste-target"]';
const WORKSPACE_URL = /\/workspace\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;

// 1×1 red PNG.
const TINY_PNG_B64 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

test.describe('Clipboard to PDF (T-079)', () => {
  test('text on the clipboard becomes a PDF opened in the workspace', async ({ browser }) => {
    const context = await browser.newContext({
      permissions: ['clipboard-read', 'clipboard-write'],
    });
    const page = await context.newPage();
    await login(page);
    await page.goto('/workspace/doc-1');

    await page.click(CREATE_CONVERT_TAB);
    await page.waitForSelector(CLIPBOARD_BTN);

    // Seed the clipboard with text (user gesture requirement is satisfied by
    // the click below — the read happens inside the click handler).
    await page.evaluate(() => navigator.clipboard.writeText('Hello from the clipboard test'));

    await page.click(CLIPBOARD_BTN);

    // The PDF is ingested server-side and the workspace navigates to it.
    await page.waitForURL(WORKSPACE_URL, { timeout: 15000 });
    expect(page.url()).toMatch(WORKSPACE_URL);
    await context.close();
  });

  test('image on the clipboard becomes a PDF opened in the workspace', async ({ browser }) => {
    const context = await browser.newContext({
      permissions: ['clipboard-read', 'clipboard-write'],
    });
    const page = await context.newPage();
    await login(page);
    await page.goto('/workspace/doc-1');

    await page.click(CREATE_CONVERT_TAB);
    await page.waitForSelector(CLIPBOARD_BTN);

    await page.evaluate(async (b64) => {
      const bin = atob(b64);
      const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
      const blob = new Blob([bytes], { type: 'image/png' });
      await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
    }, TINY_PNG_B64);

    await page.click(CLIPBOARD_BTN);

    await page.waitForURL(WORKSPACE_URL, { timeout: 15000 });
    expect(page.url()).toMatch(WORKSPACE_URL);
    await context.close();
  });

  test('clipboard-read denial shows the paste-target fallback', async ({ browser }) => {
    const context = await browser.newContext();
    // Simulate a denied clipboard-read permission deterministically.
    await context.addInitScript(() => {
      if (navigator.clipboard) {
        navigator.clipboard.read = () =>
          Promise.reject(Object.assign(new Error('Permission denied'), { name: 'NotAllowedError' }));
      }
    });
    const page = await context.newPage();
    await login(page);
    await page.goto('/workspace/doc-1');

    await page.click(CREATE_CONVERT_TAB);
    await page.waitForSelector(CLIPBOARD_BTN);
    await page.click(CLIPBOARD_BTN);

    await page.waitForSelector(PASTE_TARGET);
    await expect(page.locator(PASTE_TARGET)).toContainText('Clipboard access was denied');
    await context.close();
  });

  test('empty clipboard shows a plain-language message', async ({ browser }) => {
    const context = await browser.newContext({
      permissions: ['clipboard-read', 'clipboard-write'],
    });
    // writeText('') is unreliable (Chromium may return an opaque item), so
    // stub read() to resolve an empty list — the hook's exact empty path.
    await context.addInitScript(() => {
      if (navigator.clipboard) {
        navigator.clipboard.read = () => Promise.resolve([]);
      }
    });
    const page = await context.newPage();
    await login(page);
    await page.goto('/workspace/doc-1');

    await page.click(CREATE_CONVERT_TAB);
    await page.waitForSelector(CLIPBOARD_BTN);
    await page.click(CLIPBOARD_BTN);

    await page.waitForSelector(PASTE_TARGET);
    await expect(page.locator(PASTE_TARGET)).toContainText('The clipboard is empty');
    await context.close();
  });
});
