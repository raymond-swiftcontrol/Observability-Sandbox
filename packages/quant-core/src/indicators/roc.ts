/** Rate of change, as a percentage: `(value_t / value_{t-period} - 1) * 100`. O(n), no window scan needed. */
import { requireNonEmpty, requirePositiveInt, filled, safeDiv, type Series } from '../utils.js';

export function roc(values: readonly number[], period = 12): Series {
  requireNonEmpty(values, 'values');
  requirePositiveInt(period, 'period');
  const out = filled(values.length);
  for (let i = period; i < values.length; i += 1) {
    const prev = values[i - period] as number;
    out[i] = safeDiv((values[i] as number) - prev, prev, 0) * 100;
  }
  return out;
}
