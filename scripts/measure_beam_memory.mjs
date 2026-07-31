// T-058 BEAM memory measurement helper: opens 3 workspace documents in a
// headless browser and keeps them open until stdin closes, so the caller can
// sample BEAM RSS while the documents are "open" (workspace LiveViews alive).
import { chromium } from '/Users/adam2/projects/pdf/test/visual/node_modules/playwright/index.mjs';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const urls = JSON.parse(fs.readFileSync(path.join(__dirname, '../test/visual/fixture_urls.json'), 'utf-8'));
const base = process.env.BASE_URL || 'http://localhost:4000';
const PASSWORD = 'dev-password-1234';

const browser = await chromium.launch();
const ctx = await browser.newContext();
const page = await ctx.newPage();

// Login via direct POST (same as test/visual/helpers.ts)
await page.goto(base + '/users/log-in');
const csrf = await page.evaluate(() =>
  document.querySelector('meta[name="csrf-token"]')?.getAttribute('content'),
);
const resp = await page.request.post(base + '/users/log-in', {
  form: { _csrf_token: csrf, 'user[email]': 'dev@quire.test', 'user[password]': PASSWORD },
});
if (!resp.ok()) throw new Error('login failed: ' + resp.status());

const titles = ['500_pages.pdf', '50mb_images.pdf', 'cjk.pdf'];
for (const t of titles) {
  await page.goto(base + urls[t]);
  await page.waitForSelector('#pdf-viewer-container .page canvas', { timeout: 60000 });
  await page.waitForFunction(() => {
    const c = document.querySelector('#pdf-viewer-container .page canvas');
    return !!c && c.width > 0 && c.height > 0;
  });
}
console.log('THREE_DOCS_OPEN');
// Hold open until stdin closes (caller signals).
await new Promise((resolve) => process.stdin.on('data', () => resolve()));
await browser.close();
