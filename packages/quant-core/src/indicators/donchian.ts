/** Donchian Channels: the rolling high/low envelope (the basis of the classic turtle-trading breakout system). */
import { requireNonEmpty, requirePositiveInt, filled, type OhlcvBar, type Series } from '../utils.js';
import { rollingMax, rollingMin } from '../stats/rolling.js';

export interface DonchianChannelsResult {
  readonly upper: Series;
  readonly lower: Series;
  readonly middle: Series;
}

export function donchianChannels(bars: readonly OhlcvBar[], period = 20): DonchianChannelsResult {
  requireNonEmpty(bars, 'bars');
  requirePositiveInt(period, 'period');
  const upper = rollingMax(
    bars.map((b) => b.high),
    period,
  );
  const lower = rollingMin(
    bars.map((b) => b.low),
    period,
  );
  const middle = filled(bars.length);
  for (let i = 0; i < bars.length; i += 1) {
    const u = upper[i];
    const l = lower[i];
    if (u !== null && l !== null) middle[i] = (u + l) / 2;
  }
  return { upper, lower, middle };
}
