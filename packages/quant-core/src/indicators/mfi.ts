/**
 * Money Flow Index: RSI's logic applied to "money flow" (typical price *
 * volume) instead of price alone, so a move on heavy volume counts for more
 * than the same move on thin volume. Rolling sums via running totals: O(n).
 */
import { requireNonEmpty, requirePositiveInt, filled, type OhlcvBar, type Series } from '../utils.js';

export function mfi(bars: readonly OhlcvBar[], period = 14): Series {
  requireNonEmpty(bars, 'bars');
  requirePositiveInt(period, 'period');
  const n = bars.length;
  const typicalPrice = bars.map((b) => (b.high + b.low + b.close) / 3);
  const rawFlow = typicalPrice.map((tp, i) => tp * (bars[i] as OhlcvBar).volume);

  // Signed money flow per bar (positive/negative bucket), 0 for bar 0 (no prior bar to compare).
  const positiveFlow = new Array<number>(n).fill(0);
  const negativeFlow = new Array<number>(n).fill(0);
  for (let i = 1; i < n; i += 1) {
    if (typicalPrice[i]! > typicalPrice[i - 1]!) positiveFlow[i] = rawFlow[i]!;
    else if (typicalPrice[i]! < typicalPrice[i - 1]!) negativeFlow[i] = rawFlow[i]!;
  }

  const out = filled(n);
  let posSum = 0;
  let negSum = 0;
  for (let i = 0; i < n; i += 1) {
    posSum += positiveFlow[i] as number;
    negSum += negativeFlow[i] as number;
    if (i >= period) {
      posSum -= positiveFlow[i - period] as number;
      negSum -= negativeFlow[i - period] as number;
    }
    if (i >= period - 1) {
      if (posSum === 0 && negSum === 0) out[i] = 50; // no directional flow at all: neutral, not "extreme"
      else if (negSum === 0) out[i] = 100;
      else out[i] = 100 - 100 / (1 + posSum / negSum);
    }
  }
  return out;
}
