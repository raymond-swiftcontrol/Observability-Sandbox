/**
 * Average True Range via Wilder smoothing. True range accounts for gaps
 * (the high-low range alone misses a gap-open bar's real movement), and the
 * Wilder recurrence keeps this O(n) instead of O(n * period).
 */
import { requireNonEmpty, requirePositiveInt, filled, type OhlcvBar, type Series } from '../utils.js';

export function trueRange(bars: readonly OhlcvBar[]): number[] {
  requireNonEmpty(bars, 'bars');
  const out: number[] = [bars[0]!.high - bars[0]!.low];
  for (let i = 1; i < bars.length; i += 1) {
    const bar = bars[i] as OhlcvBar;
    const prevClose = (bars[i - 1] as OhlcvBar).close;
    out.push(Math.max(bar.high - bar.low, Math.abs(bar.high - prevClose), Math.abs(bar.low - prevClose)));
  }
  return out;
}

export function atr(bars: readonly OhlcvBar[], period = 14): Series {
  requireNonEmpty(bars, 'bars');
  requirePositiveInt(period, 'period');
  const tr = trueRange(bars);
  const out = filled(bars.length);
  if (tr.length <= period) return out;

  let avg = 0;
  for (let i = 0; i < period; i += 1) avg += tr[i] as number;
  avg /= period;
  out[period] = avg;

  for (let i = period + 1; i < tr.length; i += 1) {
    avg = (avg * (period - 1) + (tr[i] as number)) / period;
    out[i] = avg;
  }
  return out;
}
