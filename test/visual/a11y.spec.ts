import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { login } from './helpers';

/**
 * Baseline a11y scan.
 *
 * Pre-existing violations (button-name, color-contrast, duplicate-id-active,
 * empty-heading, list) are tracked via the summary output so we can
 * drive them to zero incrementally.  Each page/tab has a known-violation
 * threshold; raise it only after triaging new violations.
 */

const KNOWN_VIOLATION_MAX = 50;

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

function logViolations(page: string, violations: readonly { id: string; impact?: string; help?: string; nodes?: unknown[] }[]) {
  if (violations.length > 0) {
    console.log(`[a11y] ${page}: ${violations.length} critical/serious violations`);
    for (const v of violations) {
      console.log(`  ${v.id} (${v.impact}): ${v.help} — ${v.nodes?.length ?? 0} nodes`);
    }
  }
}

test.describe('Home page a11y', () => {
  test('baseline scan — critical/serious violations within threshold', async ({ page }) => {
    await page.goto('/');
    await page.waitForSelector('body');

    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze();

    const violations = results.violations.filter(
      v => v.impact === 'critical' || v.impact === 'serious',
    );

    logViolations('Home page', violations);
    expect(violations.length).toBeLessThan(KNOWN_VIOLATION_MAX);
  });
});

test.describe('Log in page a11y', () => {
  test('baseline scan — critical/serious violations within threshold', async ({ page }) => {
    await page.goto('/users/log-in');
    await page.waitForSelector('body');

    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze();

    const violations = results.violations.filter(
      v => v.impact === 'critical' || v.impact === 'serious',
    );

    logViolations('Log in page', violations);
    expect(violations.length).toBeLessThan(KNOWN_VIOLATION_MAX);
  });
});

test.describe('Workspace a11y', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
    await page.goto('/workspace/doc-1');
    await page.waitForSelector('#workspace-shell');
  });

  test('baseline scan — critical/serious violations within threshold', async ({ page }) => {
    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze();

    const violations = results.violations.filter(
      v => v.impact === 'critical' || v.impact === 'serious',
    );

    logViolations('Workspace default', violations);
    expect(violations.length).toBeLessThan(KNOWN_VIOLATION_MAX);
  });

  for (const tab of TABS) {
    test(`baseline scan — ${tab} tab critical/serious violations within threshold`, async ({ page }) => {
      await page.click(`button[role="tab"][phx-value-tab="${tab}"]`);
      await page.waitForTimeout(300);

      const results = await new AxeBuilder({ page })
        .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
        .analyze();

      const violations = results.violations.filter(
        v => v.impact === 'critical' || v.impact === 'serious',
      );

      logViolations(`Workspace ${tab}`, violations);
      expect(violations.length).toBeLessThan(KNOWN_VIOLATION_MAX);
    });
  }
});
