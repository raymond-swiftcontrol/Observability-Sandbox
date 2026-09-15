/**
 * Stochastic oscillator: where the close sits within the recent high/low
 * range, as a percentage. `rollingMin`/`rollingMax` are the monotonic-deque
 * O(n) versions from stats/, not a naive O(n * period) rescan.
 */
import { requireNonEmpty, requirePositiveInt, safeDiv, filled, type OhlcvBar, type Series } from '../utils.js';
import { rollingMax, rollingMin } from '../stats/rolling.js';
import { sma } from './moving-averages.js';
import { realign, trimLeadingNulls } from './_internal.js';

export interface StochasticResult {
  readonly k: Series;
  readonly d: Series;
}

/**
 * @param kPeriod lookback for the high/low range.
 * @param kSmoothing SMA period applied to the raw %K (1 = "fast" stochastic, the unsmoothed classic; 3 = the common "slow" %K).
 * @param dPeriod SMA period applied to %K to produce %D, the signal line.
 */
export function stochastic(
  bars: readonly OhlcvBar[],
  kPeriod = 14,
  kSmoothing = 3,
  dPeriod = 3,
): StochasticResult {
  requireNonEmpty(bars, 'bars');
  requirePositiveInt(kPeriod, 'kPeriod');
  requirePositiveInt(kSmoothing, 'kSmoothing');
  requirePositiveInt(dPeriod, 'dPeriod');

  const highs = bars.map((b) => b.high);
  const lows = bars.map((b) => b.low);
  const closes = bars.map((b) => b.close);
  const highestHigh = rollingMax(highs, kPeriod);
  const lowestLow = rollingMin(lows, kPeriod);

  const rawK = filled(bars.length);
  for (let i = 0; i < bars.length; i += 1) {
    const hh = highestHigh[i];
    const ll = lowestLow[i];
    if (hh === null || ll === null) continue;
    rawK[i] = safeDiv((closes[i] as number) - ll, hh - ll, 50) * 100;
  }

  const { offset: kOffset, values: rawKValues } = trimLeadingNulls(rawK);
  const smoothedK: Series = kSmoothing === 1 ? rawKValues : sma(rawKValues, kSmoothing);
  const k = realign(bars.length, kOffset, smoothedK);

  const { offset: dOffset, values: kValues } = trimLeadingNulls(k);
  const d = realign(bars.length, dOffset, sma(kValues, dPeriod));

  return { k, d };
}
