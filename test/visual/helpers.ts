import { Page } from '@playwright/test';

const EMAIL = 'dev@quire.test';
const PASSWORD = 'dev-password-1234';

/**
 * Log in to the app by POSTing the login form directly.
 * Assumes the seed user exists (run `mix run priv/repo/seeds.exs`).
 *
 * Uses direct HTTP POST rather than the LiveView form (which requires
 * a working WebSocket connection) so it works even with compilation
 * errors in other parts of the app.
 */
export async function login(page: Page) {
  await page.goto('/users/log-in');

  // Read CSRF token from the page meta tag
  const csrfToken = await page.evaluate(() =>
    document.querySelector('meta[name="csrf-token"]')?.getAttribute('content'),
  );

  // POST directly — the session cookie lands on the shared context
  const resp = await page.request.post('/users/log-in', {
    form: {
      _csrf_token: csrfToken!,
      'user[email]': EMAIL,
      'user[password]': PASSWORD,
    },
  });

  if (!resp.ok()) {
    throw new Error(`Login failed: ${resp.status()} ${resp.statusText()}`);
  }
}
