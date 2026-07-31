import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { login } from './helpers';

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

test.describe('Home page a11y', () => {
  test('should not have any critical or serious violations', async ({ page }) => {
    await page.goto('/');
    await page.waitForSelector('body');

    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze();

    expect(results.violations.filter(v => v.impact === 'critical' || v.impact === 'serious')).toEqual([]);
  });
});

test.describe('Log in page a11y', () => {
  test('should not have any critical or serious violations', async ({ page }) => {
    await page.goto('/users/log-in');
    await page.waitForSelector('body');

    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze();

    expect(results.violations.filter(v => v.impact === 'critical' || v.impact === 'serious')).toEqual([]);
  });
});

test.describe('Workspace a11y', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
    await page.goto('/workspace/doc-1');
    await page.waitForSelector('#workspace-shell');
  });

  test('default view tab should not have critical or serious violations', async ({ page }) => {
    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze();

    expect(results.violations.filter(v => v.impact === 'critical' || v.impact === 'serious')).toEqual([]);
  });

  for (const tab of TABS) {
    test(`${tab} tab should not have critical or serious violations`, async ({ page }) => {
      await page.click(`button[role="tab"][phx-value-tab="${tab}"]`);
      await page.waitForTimeout(300);

      const results = await new AxeBuilder({ page })
        .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
        .analyze();

      expect(results.violations.filter(v => v.impact === 'critical' || v.impact === 'serious')).toEqual([]);
    });
  }
});
