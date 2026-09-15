/**
 * Average Directional Index (Wilder). Measures trend *strength* regardless
 * of direction; `plusDI`/`minusDI` carry the direction. All three
 * intermediate series (+DM, -DM, TR) share the same Wilder-smoothing
 * recurrence as `atr`, so this is O(n) end to end.
 */
import { requireNonEmpty, requirePositiveInt, safeDiv, filled, type OhlcvBar, type Series } from '../utils.js';
import { trueRange } from './atr.js';

export interface AdxResult {
  readonly adx: Series;
  readonly plusDI: Series;
  readonly minusDI: Series;
}

function wilderSmooth(values: readonly number[], period: number): (number | null)[] {
  const out = new Array<number | null>(values.length).fill(null);
  if (values.length < period) return out;
  let avg = 0;
  for (let i = 0; i < period; i += 1) avg += values[i] as number;
  out[period - 1] = avg;
  for (let i = period; i < values.length; i += 1) {
    avg = avg - avg / period + (values[i] as number);
    out[i] = avg;
  }
  return out;
}

export function adx(bars: readonly OhlcvBar[], period = 14): AdxResult {
  requireNonEmpty(bars, 'bars');
  requirePositiveInt(period, 'period');
  const n = bars.length;
  const plusDI = filled(n);
  const minusDI = filled(n);
  const adxOut = filled(n);
  if (n < period + 1) return { adx: adxOut, plusDI, minusDI };

  const tr = trueRange(bars);
  const plusDM: number[] = [0];
  const minusDM: number[] = [0];
  for (let i = 1; i < n; i += 1) {
    const upMove = (bars[i] as OhlcvBar).high - (bars[i - 1] as OhlcvBar).high;
    const downMove = (bars[i - 1] as OhlcvBar).low - (bars[i] as OhlcvBar).low;
    plusDM.push(upMove > downMove && upMove > 0 ? upMove : 0);
    minusDM.push(downMove > upMove && downMove > 0 ? downMove : 0);
  }

  // Smooth from index 1 onward: index 0's TR/DM has no prior bar to compare against.
  const smoothedTR = wilderSmooth(tr.slice(1), period);
  const smoothedPlusDM = wilderSmooth(plusDM.slice(1), period);
  const smoothedMinusDM = wilderSmooth(minusDM.slice(1), period);

  const dx: (number | null)[] = new Array(smoothedTR.length).fill(null);
  for (let i = 0; i < smoothedTR.length; i += 1) {
    const strTot = smoothedTR[i];
    const sPlus = smoothedPlusDM[i];
    const sMinus = smoothedMinusDM[i];
    if (strTot == null || sPlus == null || sMinus == null) continue;
    const globalIndex = i + 1; // shift back for the slice(1) above
    const pdi = safeDiv(sPlus, strTot, 0) * 100;
    const mdi = safeDiv(sMinus, strTot, 0) * 100;
    plusDI[globalIndex] = pdi;
    minusDI[globalIndex] = mdi;
    dx[i] = safeDiv(Math.abs(pdi - mdi), pdi + mdi, 0) * 100;
  }

  const { offset, values: dxValues } = trimDxLeadingNulls(dx);
  if (dxValues.length >= period) {
    let avg = 0;
    for (let i = 0; i < period; i += 1) avg += dxValues[i] as number;
    avg /= period;
    adxOut[offset + period - 1 + 1] = avg; // +1 to undo the slice(1) shift, matching plusDI/minusDI alignment
    for (let i = period; i < dxValues.length; i += 1) {
      avg = (avg * (period - 1) + (dxValues[i] as number)) / period;
      adxOut[offset + i + 1] = avg;
    }
  }

  return { adx: adxOut, plusDI, minusDI };
}

function trimDxLeadingNulls(dx: readonly (number | null)[]): { offset: number; values: number[] } {
  let offset = 0;
  while (offset < dx.length && dx[offset] == null) offset += 1;
  return { offset, values: dx.slice(offset) as number[] };
}
