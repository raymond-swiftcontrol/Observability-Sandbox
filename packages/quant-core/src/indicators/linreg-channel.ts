/**
 * Rolling linear regression channel: fits a least-squares line to each
 * trailing window and bands it by the residual standard deviation — a
 * "best-fit trendline with volatility bands" rather than Bollinger's
 * horizontal SMA baseline.
 */
import { requireNonEmpty, requirePositiveInt, filled, type Series } from '../utils.js';
import { simpleLinearRegression } from '../stats/regression.js';

export interface LinearRegressionChannelResult {
  /** The fitted line's value at the *last* bar of each window (i.e. the current projection). */
  readonly middle: Series;
  readonly upper: Series;
  readonly lower: Series;
  readonly slope: Series;
}

export function linearRegressionChannel(
  values: readonly number[],
  period = 100,
  stdDevMultiplier = 2,
): LinearRegressionChannelResult {
  requireNonEmpty(values, 'values');
  requirePositiveInt(period, 'period');

  const middle = filled(values.length);
  const upper = filled(values.length);
  const lower = filled(values.length);
  const slope = filled(values.length);
  const xs = Array.from({ length: period }, (_, i) => i);

  for (let end = period - 1; end < values.length; end += 1) {
    const window = values.slice(end - period + 1, end + 1);
    const { slope: m, intercept } = simpleLinearRegression(xs, window);
    const fitted = xs.map((x) => m * x + intercept);
    let sumSqResidual = 0;
    for (let i = 0; i < period; i += 1) sumSqResidual += ((window[i] as number) - (fitted[i] as number)) ** 2;
    const residualStdDev = Math.sqrt(sumSqResidual / period);

    const lastFitted = fitted[period - 1] as number;
    middle[end] = lastFitted;
    upper[end] = lastFitted + stdDevMultiplier * residualStdDev;
    lower[end] = lastFitted - stdDevMultiplier * residualStdDev;
    slope[end] = m;
  }

  return { middle, upper, lower, slope };
}
