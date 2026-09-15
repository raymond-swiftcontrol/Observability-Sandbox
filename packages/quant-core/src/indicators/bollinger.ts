/** Bollinger Bands: an SMA envelope at +/- `stdDevMultiplier` rolling standard deviations. */
import { requireNonEmpty, requirePositiveInt, filled, type Series } from '../utils.js';
import { sma } from './moving-averages.js';
import { rollingStdDev } from '../stats/rolling.js';

export interface BollingerBandsResult {
  readonly middle: Series;
  readonly upper: Series;
  readonly lower: Series;
  /** (upper - lower) / middle — a normalised measure of band width, useful for squeeze detection. */
  readonly bandwidth: Series;
}

export function bollingerBands(
  values: readonly number[],
  period = 20,
  stdDevMultiplier = 2,
): BollingerBandsResult {
  requireNonEmpty(values, 'values');
  requirePositiveInt(period, 'period');
  const middle = sma(values, period);
  // Population stddev is the Bollinger-Bands convention (matches the reference charting platforms).
  const stddev = rollingStdDev(values, period, false);

  const upper = filled(values.length);
  const lower = filled(values.length);
  const bandwidth = filled(values.length);
  for (let i = 0; i < values.length; i += 1) {
    const m = middle[i];
    const sd = stddev[i];
    if (m === null || sd === null) continue;
    upper[i] = m + stdDevMultiplier * sd;
    lower[i] = m - stdDevMultiplier * sd;
    bandwidth[i] = m === 0 ? 0 : ((upper[i] as number) - (lower[i] as number)) / m;
  }
  return { middle, upper, lower, bandwidth };
}
