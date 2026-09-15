/**
 * Relative Strength Index via Wilder smoothing — an EMA-like recurrence with
 * smoothing factor 1/period rather than the plain SMA-of-gains-and-losses
 * some implementations use. O(n) total instead of the O(n * period) a naive
 * "re-average the last `period` gains/losses every bar" approach costs.
 */
import { requirePositiveInt, requireNonEmpty, filled, type Series } from '../utils.js';

export function rsi(values: readonly number[], period = 14): Series {
  requireNonEmpty(values, 'values');
  requirePositiveInt(period, 'period');
  const out = filled(values.length);
  if (values.length <= period) return out;

  let avgGain = 0;
  let avgLoss = 0;
  for (let i = 1; i <= period; i += 1) {
    const change = (values[i] as number) - (values[i - 1] as number);
    if (change > 0) avgGain += change;
    else avgLoss += -change;
  }
  avgGain /= period;
  avgLoss /= period;
  out[period] = rsiFromAverages(avgGain, avgLoss);

  for (let i = period + 1; i < values.length; i += 1) {
    const change = (values[i] as number) - (values[i - 1] as number);
    const gain = change > 0 ? change : 0;
    const loss = change < 0 ? -change : 0;
    // Wilder smoothing: a period-length EMA of gains and losses.
    avgGain = (avgGain * (period - 1) + gain) / period;
    avgLoss = (avgLoss * (period - 1) + loss) / period;
    out[i] = rsiFromAverages(avgGain, avgLoss);
  }
  return out;
}

function rsiFromAverages(avgGain: number, avgLoss: number): number {
  if (avgLoss === 0) return avgGain === 0 ? 50 : 100;
  const rs = avgGain / avgLoss;
  return 100 - 100 / (1 + rs);
}
