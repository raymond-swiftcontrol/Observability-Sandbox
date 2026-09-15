import { describe, expect, it } from 'vitest';
import { QuantError } from '../utils.js';
import { autocorrelation, hurstExponent, simpleLinearRegression } from './regression.js';

describe('simpleLinearRegression', () => {
  it('recovers exact slope/intercept for a perfectly linear series', () => {
    const x = [1, 2, 3, 4, 5];
    const y = x.map((v) => 2 * v + 3);
    const result = simpleLinearRegression(x, y);
    expect(result.slope).toBeCloseTo(2, 10);
    expect(result.intercept).toBeCloseTo(3, 10);
    expect(result.r2).toBeCloseTo(1, 10);
  });

  it('is 0-safe when x has zero variance', () => {
    const result = simpleLinearRegression([5, 5, 5], [1, 2, 3]);
    expect(result.slope).toBe(0);
    expect(result.r2).toBe(0);
  });

  it('gives a low r2 for pure noise around a flat mean', () => {
    const x = [1, 2, 3, 4, 5, 6];
    const y = [10, 3, 12, 2, 11, 4]; // no real linear relation to x
    const result = simpleLinearRegression(x, y);
    expect(result.r2).toBeLessThan(0.5);
  });

  it('throws with fewer than 2 points', () => {
    expect(() => simpleLinearRegression([1], [1])).toThrow(QuantError);
  });
});

describe('autocorrelation', () => {
  it('lag 0 is always 1 (for non-degenerate series)', () => {
    expect(autocorrelation([1, 2, 3, 4, 5, 6, 7], 0)).toBeCloseTo(1, 10);
  });

  it('is close to 1 for a perfectly repeating-with-lag pattern, given enough periods', () => {
    // A pure sine wave shifted by exactly one full period is identical to itself, so the only
    // reason the estimator isn't exactly 1 is that it sums (n-lag) products over a variance
    // computed from all n points — with lag << n that gap shrinks to nothing.
    const n = 800;
    const period = 8;
    const values = Array.from({ length: n }, (_, i) => Math.sin((2 * Math.PI * i) / period));
    expect(autocorrelation(values, period)).toBeGreaterThan(0.95);
  });

  it('is 0 for a zero-variance series rather than NaN', () => {
    expect(autocorrelation([3, 3, 3, 3], 1)).toBe(0);
  });

  it('throws for an out-of-range lag', () => {
    expect(() => autocorrelation([1, 2, 3], 3)).toThrow(QuantError);
    expect(() => autocorrelation([1, 2, 3], -1)).toThrow(QuantError);
  });
});

describe('hurstExponent', () => {
  function seededRandom(seed: number): () => number {
    let state = seed;
    return () => {
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      return state / 0x7fffffff;
    };
  }

  it('is higher for a strongly trending series than for a mean-reverting one', () => {
    const rand = seededRandom(42);
    const n = 512;

    // Trending: a persistent drift plus small noise.
    let trendLevel = 0;
    const trending = Array.from({ length: n }, () => {
      trendLevel += 0.1 + (rand() - 0.5) * 0.05;
      return trendLevel;
    });

    // Mean-reverting: oscillates around 0 by construction (alternating sign, bounded).
    const meanReverting = Array.from({ length: n }, (_, i) => (i % 2 === 0 ? 1 : -1) + (rand() - 0.5) * 0.01);

    expect(hurstExponent(trending)).toBeGreaterThan(hurstExponent(meanReverting));
  });

  it('throws on a too-short series', () => {
    expect(() => hurstExponent([1, 2, 3])).toThrow(QuantError);
  });
});
