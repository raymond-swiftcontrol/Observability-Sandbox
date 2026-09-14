import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['src/**/*.rn.test.tsx'],
    // @testing-library/react-native renders through react-test-renderer, which
    // needs a DOM-free but browser-ish global set; jsdom is the closest vitest
    // environment that satisfies react-native-web's feature checks.
    environment: 'jsdom',
    setupFiles: ['./src/test-setup.ts'],
  },
  resolve: {
    conditions: ['react-native', 'node'],
  },
});
