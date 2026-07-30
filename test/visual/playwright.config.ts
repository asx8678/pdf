import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  timeout: 30000,
  expect: {
    toMatchScreenshot: { threshold: 0.02 },
  },
  use: {
    baseURL: 'http://localhost:4000',
    locale: 'en-US',
  },
  projects: [
    {
      name: 'darwin-arm64',
      use: { browserName: 'chromium' },
    },
  ],
});
