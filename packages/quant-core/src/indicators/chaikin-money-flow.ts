/** Chaikin Money Flow: rolling sum of volume-weighted accumulation/distribution, normalised by rolling volume. */
import { requireNonEmpty, requirePositiveInt, safeDiv, filled, type OhlcvBar, type Series } from '../utils.js';

export function chaikinMoneyFlow(bars: readonly OhlcvBar[], period = 20): Series {
  requireNonEmpty(bars, 'bars');
  requirePositiveInt(period, 'period');
  const n = bars.length;
  const moneyFlowVolume = bars.map((b) => {
    const range = b.high - b.low;
    const multiplier = range === 0 ? 0 : (b.close - b.low - (b.high - b.close)) / range;
    return multiplier * b.volume;
  });
  const volumes = bars.map((b) => b.volume);

  const out = filled(n);
  let mfvSum = 0;
  let volSum = 0;
  for (let i = 0; i < n; i += 1) {
    mfvSum += moneyFlowVolume[i] as number;
    volSum += volumes[i] as number;
    if (i >= period) {
      mfvSum -= moneyFlowVolume[i - period] as number;
      volSum -= volumes[i - period] as number;
    }
    if (i >= period - 1) out[i] = safeDiv(mfvSum, volSum, 0);
  }
  return out;
}
