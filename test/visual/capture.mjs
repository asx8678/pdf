import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BASELINE_DIR = path.join(__dirname, 'darwin-arm64');
fs.mkdirSync(BASELINE_DIR, { recursive: true });

const WIDTHS = [1280, 1600, 1920];
const HEIGHT = 900;
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
const BASE_URL = 'http://localhost:4000';

async function capture() {
  const browser = await chromium.launch();
  const context = await browser.newContext({ locale: 'en-US' });

  // ── 1. Log in (direct POST — LiveView websocket may be down)
  console.log('Logging in...');
  {
    const page = await context.newPage();
    await page.goto(`${BASE_URL}/users/log-in`);
    // Extract the CSRF token from the page meta tag
    const csrfToken = await page.evaluate(() =>
      document.querySelector('meta[name="csrf-token"]')?.getAttribute('content'),
    );
    // POST the login form directly, bypassing the broken LiveView
    const resp = await page.request.post(`${BASE_URL}/users/log-in`, {
      form: {
        _csrf_token: csrfToken,
        'user[email]': 'dev@quire.test',
        'user[password]': 'dev-password-1234',
      },
    });
    console.log('Login response:', resp.status(), resp.url());
    // The session cookie is now set on the context
    await page.close();
  }

  // ── 2. Screenshots for each width and colour scheme ──
  for (const width of WIDTHS) {
    for (const mode of ['light', 'dark']) {
      console.log(`  ${width}px ${mode}`);
      const page = await context.newPage();

      // Ensure the theme is set via localStorage before any page JS runs
      await page.addInitScript((theme) => {
        localStorage.setItem('phx:theme', theme);
      }, mode);

      await page.setViewportSize({ width, height: HEIGHT });

      // --- Home page ---
      await page.goto(`${BASE_URL}/`);
      await page.waitForSelector('body');
      // Override the prefers-color-scheme CSS media query as well
      await page.emulateMedia({ colorScheme: mode });
      // Let CSS transitions and LiveView settle
      await page.waitForTimeout(500);
      await page.screenshot({
        path: path.join(BASELINE_DIR, `home-${width}px-${mode}.png`),
        fullPage: false,
      });

      // --- Workspace ---
      await page.goto(`${BASE_URL}/workspace/doc-1`);
      await page.waitForSelector('#workspace-shell');
      await page.emulateMedia({ colorScheme: mode });
      await page.waitForTimeout(500);

      // Default tab (View)
      await page.screenshot({
        path: path.join(BASELINE_DIR, `workspace-${width}px-${mode}.png`),
        fullPage: false,
      });

      // Each tab in the MenuBar
      for (const tab of TABS) {
        await page.click(`button[role="tab"][phx-value-tab="${tab}"]`);
        await page.waitForTimeout(300);
        await page.screenshot({
          path: path.join(BASELINE_DIR, `workspace-${tab}-${width}px-${mode}.png`),
          fullPage: false,
        });
      }

      await page.close();
    }
  }

  await browser.close();
  console.log('All screenshots captured in', BASELINE_DIR);
  console.log(
    `Files: ${(WIDTHS.length * 2) /* home */ + (WIDTHS.length * 2) /* workspace default */ + (WIDTHS.length * 2 * TABS.length) /* per-tab */} total`,
  );
}

capture().catch((err) => {
  console.error('Failed:', err);
  process.exit(1);
});
