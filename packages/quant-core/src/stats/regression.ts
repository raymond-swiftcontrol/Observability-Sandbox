/**
 * Ordinary least squares simple linear regression, plus autocorrelation and
 * the Hurst exponent — all "how does this series relate to itself or to
 * another" tools that build on the moments in `descriptive.ts`.
 */
import { QuantError, requireNonEmpty } from '../utils.js';
import { mean } from './descriptive.js';

export interface LinearRegressionResult {
  readonly slope: number;
  readonly intercept: number;
  /** Coefficient of determination: fraction of y's variance explained by x. */
  readonly r2: number;
}

/**
 * Simple OLS regression of y on x: y = slope * x + intercept. Closed-form,
 * O(n). Returns slope 0 / r2 0 when x has zero variance (a vertical scatter
 * has no well-defined slope, and 0 is safer than dividing by zero into NaN).
 */
export function simpleLinearRegression(
  x: readonly number[],
  y: readonly number[],
): LinearRegressionResult {
  requireNonEmpty(x, 'x');
  if (x.length !== y.length) {
    throw new QuantError('simpleLinearRegression requires equal-length arrays');
  }
  if (x.length < 2) throw new QuantError('simpleLinearRegression requires at least 2 points');

  const mx = mean(x);
  const my = mean(y);
  let sxy = 0;
  let sxx = 0;
  for (let i = 0; i < x.length; i += 1) {
    const dx = (x[i] as number) - mx;
    sxy += dx * ((y[i] as number) - my);
    sxx += dx * dx;
  }
  if (sxx === 0) return { slope: 0, intercept: my, r2: 0 };

  const slope = sxy / sxx;
  const intercept = my - slope * mx;

  let ssRes = 0;
  let ssTot = 0;
  for (let i = 0; i < x.length; i += 1) {
    const predicted = slope * (x[i] as number) + intercept;
    ssRes += ((y[i] as number) - predicted) ** 2;
    ssTot += ((y[i] as number) - my) ** 2;
  }
  const r2 = ssTot === 0 ? 1 : 1 - ssRes / ssTot;
  return { slope, intercept, r2 };
}

/**
 * Autocorrelation at lag k: correlation of the series with itself shifted by
 * k steps, using the classic ACF estimator (mean and variance taken over the
 * *whole* series rather than re-centred on each shifted subset — this is what
 * makes it a valid, comparable-across-k estimator).
 */
export function autocorrelation(values: readonly number[], lag: number): number {
  requireNonEmpty(values, 'values');
  const n = values.length;
  if (!Number.isInteger(lag) || lag < 0) {
    throw new QuantError(`lag must be a non-negative integer, got ${lag}`);
  }
  if (lag >= n) throw new QuantError('lag must be smaller than the series length');

  const m = mean(values);
  let denominator = 0;
  for (const v of values) denominator += (v - m) ** 2;
  if (denominator === 0) return 0;

  let numerator = 0;
  for (let t = 0; t < n - lag; t += 1) {
    numerator += ((values[t] as number) - m) * ((values[t + lag] as number) - m);
  }
  return numerator / denominator;
}

/**
 * Hurst exponent via classic rescaled-range (R/S) analysis, estimated by
 * regressing log(mean R/S) on log(chunk size) across a geometric ladder of
 * chunk sizes and taking the slope.
 *
 * H ≈ 0.5 is a random walk, H > 0.5 indicates trend persistence, H < 0.5
 * indicates mean reversion. This is a statistical estimate, not an exact
 * value — it needs a reasonably long series (>= 64 points here) to be
 * anything but noise, and the result should be read as directional rather
 * than precise to many decimal places.
 */
export function hurstExponent(values: readonly number[]): number {
  requireNonEmpty(values, 'values');
  const n = values.length;
  if (n < 64) throw new QuantError('hurstExponent requires at least 64 values');

  const chunkSizes: number[] = [];
  for (let size = 8; size <= Math.floor(n / 2); size = Math.floor(size * 1.5)) {
    chunkSizes.push(size);
  }
  if (chunkSizes.length < 2) throw new QuantError('hurstExponent series is too short to fit a slope');

  const logSizes: number[] = [];
  const logRS: number[] = [];
  for (const size of chunkSizes) {
    const chunkCount = Math.floor(n / size);
    let rsSum = 0;
    let rsCount = 0;
    for (let c = 0; c < chunkCount; c += 1) {
      const chunk = values.slice(c * size, (c + 1) * size);
      const chunkMean = mean(chunk);
      let cumulative = 0;
      let minCum = 0;
      let maxCum = 0;
      let sumSq = 0;
      for (const v of chunk) {
        cumulative += v - chunkMean;
        if (cumulative < minCum) minCum = cumulative;
        if (cumulative > maxCum) maxCum = cumulative;
        sumSq += (v - chunkMean) ** 2;
      }
      const range = maxCum - minCum;
      const std = Math.sqrt(sumSq / size);
      if (std > 0) {
        rsSum += range / std;
        rsCount += 1;
      }
    }
    if (rsCount > 0) {
      logSizes.push(Math.log(size));
      logRS.push(Math.log(rsSum / rsCount));
    }
  }

  if (logSizes.length < 2) throw new QuantError('hurstExponent: insufficient non-degenerate chunks');
  return simpleLinearRegression(logSizes, logRS).slope;
}
