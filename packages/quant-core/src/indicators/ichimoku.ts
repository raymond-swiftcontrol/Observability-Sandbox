/**
 * Ichimoku Kinko Hyo. `spanA`/`spanB` are conventionally plotted
 * `displacement` bars *ahead* of the data that produced them, and
 * `laggingSpan` (Chikou) is the close plotted `displacement` bars *behind* —
 * this returns them already shifted into a same-length array indexed like
 * the input, rather than the raw undisplaced values, since "shift by
 * displacement" is the part every consumer would otherwise reimplement
 * slightly differently. A real cloud chart also projects `spanA`/`spanB`
 * `displacement` bars *past* the last input bar (into dates that don't exist
 * yet); that projection is out of scope for a fixed-length array and is left
 * to the charting layer, which has the future bar slots to draw into.
 */
import { requireNonEmpty, requirePositiveInt, filled, type OhlcvBar, type Series } from '../utils.js';
import { rollingMax, rollingMin } from '../stats/rolling.js';

export interface IchimokuResult {
  readonly conversionLine: Series;
  readonly baseLine: Series;
  readonly spanA: Series;
  readonly spanB: Series;
  readonly laggingSpan: Series;
}

function midline(bars: readonly OhlcvBar[], period: number): Series {
  const highs = rollingMax(
    bars.map((b) => b.high),
    period,
  );
  const lows = rollingMin(
    bars.map((b) => b.low),
    period,
  );
  const out = filled(bars.length);
  for (let i = 0; i < bars.length; i += 1) {
    const h = highs[i];
    const l = lows[i];
    if (h !== null && l !== null) out[i] = (h + l) / 2;
  }
  return out;
}

export function ichimoku(
  bars: readonly OhlcvBar[],
  conversionPeriod = 9,
  basePeriod = 26,
  spanBPeriod = 52,
  displacement = 26,
): IchimokuResult {
  requireNonEmpty(bars, 'bars');
  requirePositiveInt(conversionPeriod, 'conversionPeriod');
  requirePositiveInt(basePeriod, 'basePeriod');
  requirePositiveInt(spanBPeriod, 'spanBPeriod');
  requirePositiveInt(displacement, 'displacement');

  const n = bars.length;
  const conversionLine = midline(bars, conversionPeriod);
  const baseLine = midline(bars, basePeriod);
  const spanBRaw = midline(bars, spanBPeriod);

  const spanA = filled(n);
  const spanB = filled(n);
  const laggingSpan = filled(n);

  for (let i = 0; i < n; i += 1) {
    if (i >= displacement) {
      const c = conversionLine[i - displacement];
      const b = baseLine[i - displacement];
      if (c !== null && b !== null) spanA[i] = (c + b) / 2;
      const sb = spanBRaw[i - displacement];
      if (sb !== null) spanB[i] = sb;
    }
    if (i + displacement < n) {
      laggingSpan[i] = bars[i + displacement]!.close;
    }
  }

  return { conversionLine, baseLine, spanA, spanB, laggingSpan };
}
