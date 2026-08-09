import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.js'],
    testTimeout: 15000,
    hookTimeout: 10000,
  },
});
