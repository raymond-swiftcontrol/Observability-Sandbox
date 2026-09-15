/**
 * Volume-Weighted Average Price, cumulative over the given bar sequence.
 * VWAP is inherently session-scoped — pass only the bars of the session you
 * want (e.g. since the day's open), since this never resets on its own.
 */
import { QuantError, requireNonEmpty, type OhlcvBar } from '../utils.js';

export function vwap(bars: readonly OhlcvBar[]): number[] {
  requireNonEmpty(bars, 'bars');
  const out: number[] = [];
  let cumulativePV = 0;
  let cumulativeVolume = 0;
  for (const bar of bars) {
    if (bar.volume < 0) throw new QuantError('vwap requires non-negative volume');
    const typicalPrice = (bar.high + bar.low + bar.close) / 3;
    cumulativePV += typicalPrice * bar.volume;
    cumulativeVolume += bar.volume;
    out.push(cumulativeVolume === 0 ? typicalPrice : cumulativePV / cumulativeVolume);
  }
  return out;
}
