import { test, expect, Page, Locator } from '@playwright/test';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import { login } from './helpers';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Workspace paths seeded by scripts/seed_workspace_fixtures.exs.
// Run that script (against the dev DB) before `mise run e2e`.
const urls: Record<string, string> = JSON.parse(
  fs.readFileSync(path.join(__dirname, 'fixture_urls.json'), 'utf-8'),
);

/**
 * Open the Edit tab of a document workspace. This drives the menu-bar tab,
 * exactly as a user would, so the Edit ribbon controls render.
 */
async function openEditTab(page: Page) {
  await login(page);
  const url = urls['simple_text.pdf'];
  expect(
    url,
    'seed simple_text.pdf first (mix run scripts/seed_workspace_fixtures.exs)',
  ).toBeTruthy();
  await page.goto(url);

  await page.waitForSelector('#pdf-viewer-container .page canvas', { timeout: 30_000 });
  await page.waitForFunction(() => {
    const c = document.querySelector('#pdf-viewer-container .page canvas') as HTMLCanvasElement | null;
    return !!c && c.width > 0 && c.height > 0;
  });
  await page.waitForTimeout(800);

  // Click the "Edit" menu-bar tab to reveal the Edit ribbon.
  await page.locator('[role="tablist"] button[role="tab"]', { hasText: 'Edit' }).click();
  await page.waitForSelector('[phx-value-mode="add_text"]', { timeout: 10_000 });
}

/** The Format painter ribbon button. */
function formatPainter(page: Page): Locator {
  return page.locator('[role="toolbar"] button[aria-label*="Format painter"]').first();
}

/** The Select text ribbon button. */
function selectText(page: Page): Locator {
  return page.locator('[role="toolbar"] button[aria-label*="Select text"]').first();
}

/** Activate Add text mode via the ribbon. */
async function activateAddText(page: Page) {
  await page.locator('[phx-value-mode="add_text"]').first().click();
}

/** Drag-create a FreeText editor at a fractional position on the first page. */
async function dragCreateText(page: Page, fx: number, fy: number) {
  const bb = (await page
    .locator('#pdf-viewer-container .page')
    .first()
    .boundingBox()) as { x: number; y: number; width: number; height: number } | null;
  if (!bb) throw new Error('page had no bounding box');
  const { x, y, width, height } = bb;
  await page.mouse.move(x + width * fx, y + height * fy);
  await page.mouse.down();
  await page.mouse.move(x + width * (fx + 0.12), y + height * (fy + 0.06), {
    steps: 5,
  });
  await page.mouse.up();
  await page.waitForTimeout(400);
}

/** The nth .freeTextEditor element (0-based) on the first page. */
function editorEl(page: Page, index: number): Locator {
  return page.locator('#pdf-viewer-container .page .freeTextEditor').nth(index);
}

interface EditorStyle {
  fontFamily: string;
  fontSize: number;
  bold: boolean;
  color: string;
  textAlign: string;
}

/**
 * Read the effective text style of the nth FreeText editor, the same
 * properties the format painter captures/applies.
 */
async function readEditorStyle(page: Page, index: number): Promise<EditorStyle | null> {
  const raw = await page.evaluate((idx) => {
    const editors = document.querySelectorAll(
      '#pdf-viewer-container .page .freeTextEditor',
    );
    const el = editors[idx];
    if (!el) return null;
    const inner = el.querySelector('[contenteditable]') as HTMLElement | null;
    const target: HTMLElement = inner || (el as HTMLElement);
    const cs = window.getComputedStyle(target);
    const weight = target.style.fontWeight || cs.fontWeight;
    return {
      fontFamily: (target.style.fontFamily || cs.fontFamily || '')
        .split(',')[0]
        .trim(),
      fontSize: parseFloat(cs.fontSize) || 0,
      bold: weight === 'bold' || parseInt(weight, 10) >= 700,
      color: target.style.color || '',
      textAlign: target.style.textAlign || cs.textAlign || 'start',
    };
  }, index);

  if (!raw || typeof raw === 'string') return null;
  return raw as unknown as EditorStyle;
}

/** Apply a distinctive style to an editor (mirrors what the format bar sets). */
async function writeEditorStyle(
  page: Page,
  index: number,
  style: Partial<EditorStyle>,
) {
  await page.evaluate((arg: { index: number; style: Partial<EditorStyle> }) => {
    const editors = document.querySelectorAll(
      '#pdf-viewer-container .page .freeTextEditor',
    );
    const el = editors[arg.index];
    if (!el) return;
    const inner = el.querySelector('[contenteditable]') as HTMLElement | null;
    if (!inner) return;
    if (arg.style.fontFamily) inner.style.fontFamily = arg.style.fontFamily;
    if (arg.style.fontSize) inner.style.fontSize = `${arg.style.fontSize}px`;
    if (arg.style.color) inner.style.color = arg.style.color;
    if (arg.style.bold) inner.style.fontWeight = 'bold';
    if (arg.style.textAlign) inner.style.textAlign = arg.style.textAlign;
  }, { index, style });
}

test('format painter button is disabled until an object is selected', async ({ page }) => {
  await openEditTab(page);

  const isPainterEnabled = () =>
    page.evaluate(() => {
      const btn = Array.from(document.querySelectorAll('[role="toolbar"] button')).find(
        (b) => (b.getAttribute('aria-label') || '').includes('Format painter'),
      );
      if (!btn) return false;
      return (
        btn.getAttribute('aria-disabled') !== 'true' &&
        !(btn as HTMLButtonElement).disabled
      );
    });

  // 1. Nothing selected yet -> the Format painter is disabled.
  expect(await isPainterEnabled()).toBe(false);

  // 2. Create a text object in Add mode so a selection exists.
  await activateAddText(page);
  await dragCreateText(page, 0.2, 0.3);
  await page.waitForSelector('#pdf-viewer-container .page .freeTextEditor', {
    timeout: 10_000,
  });

  // 3. Once an object is selected the Format painter becomes enabled.
  await expect.poll(isPainterEnabled, { timeout: 10_000 }).toBe(true);
});

test('format painter copies style to a second text object', async ({ page }) => {
  await openEditTab(page);

  // Create two text objects.
  await activateAddText(page);
  await dragCreateText(page, 0.15, 0.25); // object A
  await dragCreateText(page, 0.55, 0.25); // object B
  await page.waitForFunction(
    () =>
      document.querySelectorAll('#pdf-viewer-container .page .freeTextEditor').length >=
      2,
    undefined,
    { timeout: 10_000 },
  );

  // Give object A a distinctive style.
  await writeEditorStyle(page, 0, {
    fontFamily: 'Courier',
    fontSize: 28,
    color: '#ff0000',
    textAlign: 'center',
    bold: true,
  });

  const aStyle = (await readEditorStyle(page, 0))!;
  const bBefore = (await readEditorStyle(page, 1))!;
  expect(aStyle.fontSize).toBe(28);

  // Select object A and arm the Format painter (copies A's style).
  await editorEl(page, 0).click();
  await page.waitForTimeout(200);
  await formatPainter(page).click();
  await page.waitForTimeout(200);

  // Click object B to apply the copied style.
  await editorEl(page, 1).click();
  await page.waitForTimeout(300);

  const bAfter = (await readEditorStyle(page, 1))!;

  // Target properties must now match the source's captured style.
  expect(bAfter.fontFamily).toBe(aStyle.fontFamily.split(',')[0]);
  expect(bAfter.fontSize).toBe(aStyle.fontSize);
  expect(bAfter.bold).toBe(aStyle.bold);
  expect(bAfter.color.toLowerCase()).toBe(aStyle.color.toLowerCase());
  expect(bAfter.textAlign).toBe('center');

  // And the transfer changed the target from its original size.
  expect(bAfter.fontSize).not.toBe(bBefore.fontSize);
});

test('select text switches the pointer and is exclusive with object selection', async ({
  page,
}) => {
  await openEditTab(page);

  await selectText(page).click();
  await page.waitForTimeout(200);

  // The container gets a select-text class, switching the cursor.
  const cls = await page.evaluate(() => {
    return document.querySelector('#pdf-viewer-container')?.className || '';
  });
  expect(cls).toContain('select-text-mode');

  // Pointer mode switches to text selection: user-select becomes text.
  const textUserSelect = await page.evaluate(() => {
    const el = document.querySelector('#pdf-viewer-container .textLayer span');
    return el ? getComputedStyle(el).userSelect : null;
  });
  expect(textUserSelect).toBe('text');

  // Exclusive with the object/annotation editor: its mode is NONE (0).
  const editorMode = await page.evaluate(() => {
    const viewer = (document.querySelector('#document-canvas') as any)._pdfViewer;
    return viewer ? viewer.annotationEditorMode : null;
  });
  expect(editorMode).toBe(0);

  // Switching to an object tool leaves select-text mode.
  await page.locator('[role="tablist"] button[role="tab"]', { hasText: 'Edit' }).click();
  await activateAddText(page);
  await page.waitForTimeout(200);
  const cls2 = await page.evaluate(() => {
    return document.querySelector('#pdf-viewer-container')?.className || '';
  });
  expect(cls2).not.toContain('select-text-mode');
});

test('format painter and select text are keyboard reachable with aria-labels', async ({
  page,
}) => {
  await openEditTab(page);

  await expect(formatPainter(page)).toHaveCount(1);
  await expect(selectText(page)).toHaveCount(1);

  const required: Array<{ locator: Locator; label: string }> = [
    { locator: formatPainter(page), label: 'Format' },
    { locator: selectText(page), label: 'Select text' },
  ];

  for (const { locator, label } of required) {
    const ariaLabel = await locator.getAttribute('aria-label');
    expect(ariaLabel, `expected an aria-label for ${label}`).toBeTruthy();
    await locator.focus();
    await expect(locator).toBeFocused();
  }
});