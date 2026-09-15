/**
 * Commodity Channel Index. Mean *absolute* deviation (not stddev) has no
 * simple incremental update the way variance does (it isn't a sum of
 * squares), so this stays O(n * period) — period is typically 20, so this is
 * fine in practice.
 */
import { requireNonEmpty, requirePositiveInt, safeDiv, filled, type OhlcvBar, type Series } from '../utils.js';
import { sma } from './moving-averages.js';

export function cci(bars: readonly OhlcvBar[], period = 20): Series {
  requireNonEmpty(bars, 'bars');
  requirePositiveInt(period, 'period');
  const typicalPrices = bars.map((b) => (b.high + b.low + b.close) / 3);
  const smaTP = sma(typicalPrices, period);

  const out = filled(bars.length);
  for (let i = period - 1; i < bars.length; i += 1) {
    const mean = smaTP[i];
    if (mean == null) continue;
    let meanDeviation = 0;
    for (let j = i - period + 1; j <= i; j += 1) {
      meanDeviation += Math.abs((typicalPrices[j] as number) - mean);
    }
    meanDeviation /= period;
    out[i] = safeDiv((typicalPrices[i] as number) - mean, 0.015 * meanDeviation, 0);
  }
  return out;
}
