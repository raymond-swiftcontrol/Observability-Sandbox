/** Keltner Channels: an EMA midline with ATR-scaled bands (volatility-adaptive, unlike Bollinger's stddev). */
import { requireNonEmpty, requirePositiveInt, filled, type OhlcvBar, type Series } from '../utils.js';
import { ema } from './moving-averages.js';
import { atr } from './atr.js';

export interface KeltnerChannelsResult {
  readonly middle: Series;
  readonly upper: Series;
  readonly lower: Series;
}

export function keltnerChannels(
  bars: readonly OhlcvBar[],
  emaPeriod = 20,
  atrPeriod = 10,
  multiplier = 2,
): KeltnerChannelsResult {
  requireNonEmpty(bars, 'bars');
  requirePositiveInt(emaPeriod, 'emaPeriod');
  requirePositiveInt(atrPeriod, 'atrPeriod');
  const closes = bars.map((b) => b.close);
  const middle = ema(closes, emaPeriod);
  const bandWidth = atr(bars, atrPeriod);

  const upper = filled(bars.length);
  const lower = filled(bars.length);
  for (let i = 0; i < bars.length; i += 1) {
    const m = middle[i];
    const a = bandWidth[i];
    if (m == null || a == null) continue;
    upper[i] = m + multiplier * a;
    lower[i] = m - multiplier * a;
  }
  return { middle, upper, lower };
}
