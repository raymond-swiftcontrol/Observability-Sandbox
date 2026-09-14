import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // Pure token/format logic runs anywhere; the component tests need the React
    // Native preset, so they are kept in *.rn.test.tsx and run by `test:rn`.
    include: ['src/**/*.test.ts'],
    environment: 'node',
  },
});
