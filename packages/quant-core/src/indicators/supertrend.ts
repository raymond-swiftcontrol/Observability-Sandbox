/**
 * Supertrend: an ATR-banded trend-following overlay that flips between
 * tracking price from below (uptrend) and above (downtrend). O(n), one pass
 * once ATR is available.
 */
import { requireNonEmpty, requirePositiveInt, filled, type OhlcvBar, type Series } from '../utils.js';
import { atr } from './atr.js';

export interface SupertrendResult {
  readonly value: Series;
  /** 1 = uptrend (line sits below price), -1 = downtrend (line sits above price), null during warm-up. */
  readonly direction: ReadonlyArray<1 | -1 | null>;
}

export function supertrend(bars: readonly OhlcvBar[], period = 10, multiplier = 3): SupertrendResult {
  requireNonEmpty(bars, 'bars');
  requirePositiveInt(period, 'period');
  const n = bars.length;
  const atrValues = atr(bars, period);
  const value = filled(n);
  const direction: (1 | -1 | null)[] = new Array(n).fill(null);

  let finalUpper = Number.NaN;
  let finalLower = Number.NaN;
  let started = false;

  for (let i = 0; i < n; i += 1) {
    const a = atrValues[i];
    if (a == null) continue;
    const bar = bars[i] as OhlcvBar;
    const mid = (bar.high + bar.low) / 2;
    const basicUpper = mid + multiplier * a;
    const basicLower = mid - multiplier * a;

    if (!started) {
      finalUpper = basicUpper;
      finalLower = basicLower;
      value[i] = bar.close <= finalUpper ? finalUpper : finalLower;
      direction[i] = value[i] === finalUpper ? -1 : 1;
      started = true;
      continue;
    }

    const prevClose = (bars[i - 1] as OhlcvBar).close;
    finalUpper = basicUpper < finalUpper || prevClose > finalUpper ? basicUpper : finalUpper;
    finalLower = basicLower > finalLower || prevClose < finalLower ? basicLower : finalLower;

    const prevDirection = direction[i - 1];
    let currentValue: number;
    let currentDirection: 1 | -1;
    if (prevDirection === -1) {
      if (bar.close <= finalUpper) {
        currentValue = finalUpper;
        currentDirection = -1;
      } else {
        currentValue = finalLower;
        currentDirection = 1;
      }
    } else {
      if (bar.close >= finalLower) {
        currentValue = finalLower;
        currentDirection = 1;
      } else {
        currentValue = finalUpper;
        currentDirection = -1;
      }
    }
    value[i] = currentValue;
    direction[i] = currentDirection;
  }

  return { value, direction };
}
