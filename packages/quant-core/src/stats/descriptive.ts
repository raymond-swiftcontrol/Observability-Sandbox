/**
 * Descriptive statistics over a sample of numbers.
 *
 * Every function here throws `QuantError` on inputs that have no defined
 * answer (empty arrays, too few points for the requested moment) rather than
 * returning `NaN`. A `NaN` computed here would otherwise propagate silently
 * into a Sharpe ratio or a chart and be indistinguishable from a real zero.
 */
import { QuantError, requireNonEmpty } from '../utils.js';

export function sum(values: readonly number[]): number {
  let total = 0;
  for (const v of values) total += v;
  return total;
}

/** Arithmetic mean. O(n). */
export function mean(values: readonly number[]): number {
  requireNonEmpty(values, 'values');
  return sum(values) / values.length;
}

function sumSquaredDeviations(values: readonly number[], m: number): number {
  let total = 0;
  for (const v of values) total += (v - m) ** 2;
  return total;
}

/**
 * Sample variance (Bessel-corrected, divisor n-1) — the unbiased estimator of
 * the variance of the population the sample was drawn from. This is what you
 * want for "the volatility of returns we observed and want to generalise
 * from". Requires at least 2 points.
 */
export function varianceSample(values: readonly number[]): number {
  requireNonEmpty(values, 'values');
  if (values.length < 2) {
    throw new QuantError('varianceSample requires at least 2 values');
  }
  return sumSquaredDeviations(values, mean(values)) / (values.length - 1);
}

/**
 * Population variance (divisor n) — the exact variance of the given values
 * themselves, with no correction for having sampled them from a larger
 * population. Correct when `values` *is* the whole population (e.g. every bar
 * in a fixed backtest window you are describing, not generalising from).
 */
export function variancePopulation(values: readonly number[]): number {
  requireNonEmpty(values, 'values');
  return sumSquaredDeviations(values, mean(values)) / values.length;
}

export function stddevSample(values: readonly number[]): number {
  return Math.sqrt(varianceSample(values));
}

export function stddevPopulation(values: readonly number[]): number {
  return Math.sqrt(variancePopulation(values));
}

/**
 * Bias-corrected sample skewness (Fisher-Pearson adjusted, Excel `SKEW`
 * convention). Zero for a symmetric distribution, positive for a right tail.
 * Requires at least 3 points; returns 0 when the sample has zero variance
 * (all values identical) rather than dividing 0/0 into NaN.
 */
export function skewness(values: readonly number[]): number {
  requireNonEmpty(values, 'values');
  const n = values.length;
  if (n < 3) throw new QuantError('skewness requires at least 3 values');
  const m = mean(values);
  const s = stddevSample(values);
  if (s === 0) return 0;
  let cubedSum = 0;
  for (const v of values) cubedSum += (v - m) ** 3;
  const g1 = cubedSum / n / s ** 3;
  return (Math.sqrt(n * (n - 1)) / (n - 2)) * g1;
}

/**
 * Raw (non-excess) population kurtosis: the fourth standardized moment,
 * m4/m2^2. A normal distribution has a value of 3 here — subtract 3 yourself
 * if you want the "excess" convention, or use `kurtosisExcess` for the
 * bias-corrected sample version used by Excel's `KURT`.
 */
export function kurtosisPopulation(values: readonly number[]): number {
  requireNonEmpty(values, 'values');
  const m = mean(values);
  const variance = variancePopulation(values);
  if (variance === 0) return 0;
  let fourthSum = 0;
  for (const v of values) fourthSum += (v - m) ** 4;
  const m4 = fourthSum / values.length;
  return m4 / variance ** 2;
}

/**
 * Bias-corrected sample excess kurtosis (Excel `KURT` convention). 0 for a
 * normal distribution, positive for fat tails. Requires at least 4 points.
 */
export function kurtosisExcess(values: readonly number[]): number {
  requireNonEmpty(values, 'values');
  const n = values.length;
  if (n < 4) throw new QuantError('kurtosisExcess requires at least 4 values');
  const m = mean(values);
  const s = stddevSample(values);
  if (s === 0) return 0;
  let fourthSum = 0;
  for (const v of values) fourthSum += (v - m) ** 4;
  const term1 = (n * (n + 1)) / ((n - 1) * (n - 2) * (n - 3));
  const term2 = fourthSum / s ** 4;
  const term3 = (3 * (n - 1) ** 2) / ((n - 2) * (n - 3));
  return term1 * term2 - term3;
}

/**
 * Sample covariance (divisor n-1) between two equal-length series. Sample
 * rather than population because every finance use of this (beta, portfolio
 * variance from a covariance matrix) treats the observed history as a sample
 * of a return-generating process, not the whole of it.
 */
export function covariance(x: readonly number[], y: readonly number[]): number {
  requireNonEmpty(x, 'x');
  if (x.length !== y.length) throw new QuantError('covariance requires equal-length arrays');
  if (x.length < 2) throw new QuantError('covariance requires at least 2 values');
  const mx = mean(x);
  const my = mean(y);
  let total = 0;
  for (let i = 0; i < x.length; i += 1) {
    total += ((x[i] as number) - mx) * ((y[i] as number) - my);
  }
  return total / (x.length - 1);
}

/**
 * Pearson product-moment correlation coefficient, in [-1, 1]. Returns 0 when
 * either series has zero variance (undefined correlation, but 0 is the safe
 * "no linear relationship detectable" answer rather than NaN).
 */
export function pearsonCorrelation(x: readonly number[], y: readonly number[]): number {
  const sx = stddevSample(x);
  const sy = stddevSample(y);
  if (sx === 0 || sy === 0) return 0;
  return covariance(x, y) / (sx * sy);
}

/** Average ("fractional") ranks, ties sharing the mean rank of their block. */
function averageRanks(values: readonly number[]): number[] {
  const n = values.length;
  const order = Array.from({ length: n }, (_, i) => i).sort(
    (a, b) => (values[a] as number) - (values[b] as number),
  );
  const ranks = new Array<number>(n);
  let i = 0;
  while (i < n) {
    let j = i;
    // Extend over the run of tied values so they all get the block's mean rank.
    while (j + 1 < n && values[order[j + 1] as number] === values[order[i] as number]) j += 1;
    const avgRank = (i + j) / 2 + 1; // ranks are 1-based
    for (let k = i; k <= j; k += 1) ranks[order[k] as number] = avgRank;
    i = j + 1;
  }
  return ranks;
}

/**
 * Spearman rank correlation: Pearson correlation of the ranks. Captures
 * monotonic (not just linear) relationships and is robust to outliers, at the
 * cost of discarding magnitude information. O(n log n) from the rank sort.
 */
export function spearmanCorrelation(x: readonly number[], y: readonly number[]): number {
  requireNonEmpty(x, 'x');
  if (x.length !== y.length) {
    throw new QuantError('spearmanCorrelation requires equal-length arrays');
  }
  return pearsonCorrelation(averageRanks(x), averageRanks(y));
}

/**
 * Quantile with linear interpolation between closest ranks — the "R-7" /
 * `numpy.percentile` default / Excel `PERCENTILE.INC` method. `p` in [0, 1].
 */
export function quantile(values: readonly number[], p: number): number {
  requireNonEmpty(values, 'values');
  if (p < 0 || p > 1) throw new QuantError(`quantile p must be in [0, 1], got ${p}`);
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted.length === 1) return sorted[0] as number;
  const rank = p * (sorted.length - 1);
  const lower = Math.floor(rank);
  const upper = Math.ceil(rank);
  if (lower === upper) return sorted[lower] as number;
  const weight = rank - lower;
  return (sorted[lower] as number) * (1 - weight) + (sorted[upper] as number) * weight;
}
