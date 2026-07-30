import { test, expect } from '@playwright/test';
import { login } from './helpers';

test('app loads and shows Quire in the title', async ({ page }) => {
  await login(page);
  await page.goto('/');
  await page.waitForSelector('body');
  await expect(page).toHaveTitle(/Quire/);
});
