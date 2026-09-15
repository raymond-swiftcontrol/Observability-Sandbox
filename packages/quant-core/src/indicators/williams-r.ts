/** Williams %R: like the stochastic %K, but scaled to [-100, 0] and inverted (0 = at the high, -100 = at the low). */
import { requireNonEmpty, requirePositiveInt, safeDiv, filled, type OhlcvBar, type Series } from '../utils.js';
import { rollingMax, rollingMin } from '../stats/rolling.js';

export function williamsR(bars: readonly OhlcvBar[], period = 14): Series {
  requireNonEmpty(bars, 'bars');
  requirePositiveInt(period, 'period');
  const highestHigh = rollingMax(
    bars.map((b) => b.high),
    period,
  );
  const lowestLow = rollingMin(
    bars.map((b) => b.low),
    period,
  );
  const out = filled(bars.length);
  for (let i = 0; i < bars.length; i += 1) {
    const hh = highestHigh[i];
    const ll = lowestLow[i];
    if (hh === null || ll === null) continue;
    const close = (bars[i] as OhlcvBar).close;
    out[i] = safeDiv(hh - close, hh - ll, 0) * -100;
  }
  return out;
}
