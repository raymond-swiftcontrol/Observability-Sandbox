/**
 * Parabolic SAR (Wilder): a trailing stop-and-reverse level that accelerates
 * toward price as a trend persists. Inherently sequential/stateful (each
 * bar's value depends on the trend direction, extreme point and acceleration
 * factor carried from the last), so this is a single O(n) forward pass with
 * no way to vectorize further.
 */
import { requireNonEmpty, type OhlcvBar } from '../utils.js';

export interface ParabolicSarResult {
  readonly value: number[];
  /** 1 = uptrend, -1 = downtrend. */
  readonly direction: (1 | -1)[];
}

export function parabolicSar(
  bars: readonly OhlcvBar[],
  step = 0.02,
  maxStep = 0.2,
): ParabolicSarResult {
  requireNonEmpty(bars, 'bars');
  const n = bars.length;
  const value = new Array<number>(n);
  const direction = new Array<1 | -1>(n);

  // Seed with an uptrend starting from the first bar's low — an arbitrary but standard
  // convention; the algorithm self-corrects to the true trend within a few bars.
  let uptrend = true;
  let sar = bars[0]!.low;
  let extremePoint = bars[0]!.high;
  let af = step;
  value[0] = sar;
  direction[0] = 1;

  for (let i = 1; i < n; i += 1) {
    const bar = bars[i] as OhlcvBar;
    const prevBar = bars[i - 1] as OhlcvBar;
    let nextSar = sar + af * (extremePoint - sar);

    if (uptrend) {
      // SAR may never move above the prior one or two bars' lows.
      const priorLow2 = i >= 2 ? (bars[i - 2] as OhlcvBar).low : prevBar.low;
      nextSar = Math.min(nextSar, prevBar.low, priorLow2);

      if (bar.high > extremePoint) {
        extremePoint = bar.high;
        af = Math.min(af + step, maxStep);
      }
      if (bar.low < nextSar) {
        // Reversal to downtrend: SAR jumps to the extreme point, AF and EP reset.
        uptrend = false;
        nextSar = extremePoint;
        extremePoint = bar.low;
        af = step;
      }
    } else {
      const priorHigh2 = i >= 2 ? (bars[i - 2] as OhlcvBar).high : prevBar.high;
      nextSar = Math.max(nextSar, prevBar.high, priorHigh2);

      if (bar.low < extremePoint) {
        extremePoint = bar.low;
        af = Math.min(af + step, maxStep);
      }
      if (bar.high > nextSar) {
        uptrend = true;
        nextSar = extremePoint;
        extremePoint = bar.high;
        af = step;
      }
    }

    sar = nextSar;
    value[i] = sar;
    direction[i] = uptrend ? 1 : -1;
  }

  return { value, direction };
}
