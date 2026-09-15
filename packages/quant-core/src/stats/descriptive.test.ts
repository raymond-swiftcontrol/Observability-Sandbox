import { describe, expect, it } from 'vitest';
import { QuantError } from '../utils.js';
import {
  covariance,
  kurtosisExcess,
  kurtosisPopulation,
  mean,
  pearsonCorrelation,
  quantile,
  skewness,
  spearmanCorrelation,
  stddevPopulation,
  stddevSample,
  variancePopulation,
  varianceSample,
} from './descriptive.js';

describe('mean', () => {
  it('computes the arithmetic mean', () => {
    expect(mean([1, 2, 3, 4, 5])).toBe(3);
  });

  it('throws on an empty array', () => {
    expect(() => mean([])).toThrow(QuantError);
  });

  it('handles a single-element series', () => {
    expect(mean([42])).toBe(42);
  });
});

describe('variance', () => {
  it('varianceSample matches the textbook Bessel-corrected value', () => {
    // Values 2,4,4,4,5,5,7,9: mean=5, population variance=4, sample variance=32/7.
    const values = [2, 4, 4, 4, 5, 5, 7, 9];
    expect(variancePopulation(values)).toBeCloseTo(4, 10);
    expect(varianceSample(values)).toBeCloseTo(32 / 7, 10);
  });

  it('is zero for all-identical values', () => {
    expect(variancePopulation([3, 3, 3, 3])).toBe(0);
    expect(varianceSample([3, 3, 3, 3])).toBe(0);
  });

  it('varianceSample throws with fewer than 2 values', () => {
    expect(() => varianceSample([1])).toThrow(QuantError);
    expect(() => varianceSample([])).toThrow(QuantError);
  });

  it('variancePopulation accepts a single element (zero variance)', () => {
    expect(variancePopulation([7])).toBe(0);
  });

  it('stddev is the sqrt of variance', () => {
    const values = [2, 4, 4, 4, 5, 5, 7, 9];
    expect(stddevPopulation(values)).toBeCloseTo(2, 10);
    expect(stddevSample(values)).toBeCloseTo(Math.sqrt(32 / 7), 10);
  });
});

describe('skewness', () => {
  it('is 0 for a symmetric sample', () => {
    expect(skewness([1, 2, 3, 4, 5])).toBeCloseTo(0, 10);
  });

  it('is positive for a right-skewed sample', () => {
    expect(skewness([1, 1, 1, 1, 2, 3, 10])).toBeGreaterThan(0);
  });

  it('is 0 for zero-variance input rather than NaN', () => {
    expect(skewness([5, 5, 5, 5])).toBe(0);
  });

  it('throws with fewer than 3 values', () => {
    expect(() => skewness([1, 2])).toThrow(QuantError);
  });
});

describe('kurtosis', () => {
  it('kurtosisPopulation is 0-safe for zero variance', () => {
    expect(kurtosisPopulation([4, 4, 4, 4])).toBe(0);
  });

  it('kurtosisExcess is close to 0 for a large uniform-ish symmetric sample and requires n>=4', () => {
    expect(() => kurtosisExcess([1, 2, 3])).toThrow(QuantError);
    expect(kurtosisExcess([4, 4, 4, 4])).toBe(0);
  });

  it('kurtosisExcess is markedly positive for a heavy-tailed sample', () => {
    // Mostly near 0 with a couple of extreme outliers => fat tails => positive excess kurtosis.
    const values = [0, 0.1, -0.1, 0.05, -0.05, 0.02, -0.02, 20, -20];
    expect(kurtosisExcess(values)).toBeGreaterThan(0);
  });
});

describe('covariance and correlation', () => {
  it('covariance of a series with itself equals its variance', () => {
    const values = [1, 3, 5, 7, 11];
    expect(covariance(values, values)).toBeCloseTo(varianceSample(values), 10);
  });

  it('pearsonCorrelation is 1 for a perfectly increasing linear relationship', () => {
    const x = [1, 2, 3, 4, 5];
    const y = [2, 4, 6, 8, 10];
    expect(pearsonCorrelation(x, y)).toBeCloseTo(1, 10);
  });

  it('pearsonCorrelation is -1 for a perfectly inverse linear relationship', () => {
    const x = [1, 2, 3, 4, 5];
    const y = [10, 8, 6, 4, 2];
    expect(pearsonCorrelation(x, y)).toBeCloseTo(-1, 10);
  });

  it('pearsonCorrelation is 0-safe when one series has zero variance', () => {
    expect(pearsonCorrelation([1, 1, 1], [1, 2, 3])).toBe(0);
  });

  it('spearmanCorrelation is 1 for any monotonically increasing (non-linear) relationship', () => {
    const x = [1, 2, 3, 4, 5];
    const y = [1, 4, 9, 16, 25]; // not linear, but monotonic
    expect(spearmanCorrelation(x, y)).toBeCloseTo(1, 10);
  });

  it('spearmanCorrelation handles ties via average ranks', () => {
    const x = [1, 2, 2, 4];
    const y = [1, 3, 2, 4];
    // Should not throw and should stay within [-1, 1].
    const rho = spearmanCorrelation(x, y);
    expect(rho).toBeGreaterThanOrEqual(-1);
    expect(rho).toBeLessThanOrEqual(1);
  });

  it('throws on mismatched lengths', () => {
    expect(() => covariance([1, 2], [1, 2, 3])).toThrow(QuantError);
  });
});

describe('quantile', () => {
  it('matches linear-interpolation reference values', () => {
    const values = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    expect(quantile(values, 0)).toBe(1);
    expect(quantile(values, 1)).toBe(10);
    expect(quantile(values, 0.5)).toBeCloseTo(5.5, 10);
    // R-7 / numpy default for p=0.25 over 10 sorted values 1..10: rank = 0.25*9 = 2.25 -> interpolate between index 2 (3) and 3 (4).
    expect(quantile(values, 0.25)).toBeCloseTo(3.25, 10);
  });

  it('handles a single-element array', () => {
    expect(quantile([42], 0.5)).toBe(42);
  });

  it('throws for p outside [0, 1]', () => {
    expect(() => quantile([1, 2, 3], 1.5)).toThrow(QuantError);
    expect(() => quantile([1, 2, 3], -0.1)).toThrow(QuantError);
  });

  it('throws on empty array', () => {
    expect(() => quantile([], 0.5)).toThrow(QuantError);
  });
});
