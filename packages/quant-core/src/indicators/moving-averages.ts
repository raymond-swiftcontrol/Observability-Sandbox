/**
 * Moving averages. SMA, EMA and WMA are each O(n) via an incremental update
 * (a running sum, an exponential recurrence, and a running weighted-sum
 * recurrence respectively) rather than the naive O(n * window) re-sum —
 * material on a multi-year daily series with a wide window.
 */
import { QuantError, requirePositiveInt, requireNonEmpty, filled, type Series } from '../utils.js';
import { realign, trimLeadingNulls } from './_internal.js';

/** Simple moving average via a running sum: O(n) total. */
export function sma(values: readonly number[], period: number): Series {
  requireNonEmpty(values, 'values');
  requirePositiveInt(period, 'period');
  const out = filled(values.length);
  let runningSum = 0;
  for (let i = 0; i < values.length; i += 1) {
    runningSum += values[i] as number;
    if (i >= period) runningSum -= values[i - period] as number;
    if (i >= period - 1) out[i] = runningSum / period;
  }
  return out;
}

/**
 * Exponential moving average, seeded with the SMA of the first `period`
 * values (the standard convention — an EMA has no natural starting value
 * otherwise) and then the usual recurrence
 * `ema_t = value_t * k + ema_{t-1} * (1 - k)`, `k = 2 / (period + 1)`.
 */
export function ema(values: readonly number[], period: number): Series {
  requireNonEmpty(values, 'values');
  requirePositiveInt(period, 'period');
  const out = filled(values.length);
  if (values.length < period) return out;

  const k = 2 / (period + 1);
  let seed = 0;
  for (let i = 0; i < period; i += 1) seed += values[i] as number;
  seed /= period;
  out[period - 1] = seed;

  let prev = seed;
  for (let i = period; i < values.length; i += 1) {
    prev = (values[i] as number) * k + prev * (1 - k);
    out[i] = prev;
  }
  return out;
}

/**
 * Weighted moving average (linear weights, most recent bar weighted
 * heaviest). O(n) via the recurrence `N_t = N_{t-1} + period*x_t - S_{t-1}`
 * for the weighted numerator alongside a running sum `S_t`, rather than
 * O(n * period) from re-summing every window from scratch.
 */
export function wma(values: readonly number[], period: number): Series {
  requireNonEmpty(values, 'values');
  requirePositiveInt(period, 'period');
  const out = filled(values.length);
  if (values.length < period) return out;
  const denominator = (period * (period + 1)) / 2;

  // Prime the first window directly (O(period), a one-off cost).
  let windowSum = 0; // S_{i-1}: simple sum of the window ending at the previous index
  let weightedSum = 0; // N_{i-1}: weights 1..period, heaviest on the most recent value
  for (let j = 0; j < period; j += 1) {
    const x = values[j] as number;
    windowSum += x;
    weightedSum += (j + 1) * x;
  }
  out[period - 1] = weightedSum / denominator;

  // Then slide in O(1) per step: N_i = N_{i-1} + period*x_i - S_{i-1}, S_i = S_{i-1} - x_{i-period} + x_i.
  for (let i = period; i < values.length; i += 1) {
    const xNew = values[i] as number;
    const xOld = values[i - period] as number;
    weightedSum += period * xNew - windowSum;
    windowSum += xNew - xOld;
    out[i] = weightedSum / denominator;
  }
  return out;
}

/** Double EMA: `2*EMA - EMA(EMA)`. Reduces lag versus a plain EMA at the cost of some overshoot. */
export function dema(values: readonly number[], period: number): Series {
  requireNonEmpty(values, 'values');
  requirePositiveInt(period, 'period');
  const ema1 = ema(values, period);
  const { offset, values: ema1Values } = trimLeadingNulls(ema1);
  const ema2 = ema(ema1Values, period);

  const out = filled(values.length);
  for (let i = 0; i < ema2.length; i += 1) {
    const e2 = ema2[i];
    if (e2 === null) continue;
    const e1 = ema1Values[i] as number;
    out[offset + i] = 2 * e1 - e2;
  }
  return out;
}

/** Triple EMA: `3*EMA - 3*EMA(EMA) + EMA(EMA(EMA))`. Even less lag than DEMA. */
export function tema(values: readonly number[], period: number): Series {
  requireNonEmpty(values, 'values');
  requirePositiveInt(period, 'period');
  const ema1 = ema(values, period);
  const { offset: offset1, values: ema1Values } = trimLeadingNulls(ema1);
  const ema2 = ema(ema1Values, period);
  const { offset: offset2, values: ema2Values } = trimLeadingNulls(ema2);
  const ema3 = ema(ema2Values, period);

  const totalOffset = offset1 + offset2;
  const out = filled(values.length);
  for (let i = 0; i < ema3.length; i += 1) {
    const e3 = ema3[i];
    if (e3 === null) continue;
    const e2 = ema2Values[i] as number;
    const e1 = ema1Values[offset2 + i] as number;
    out[totalOffset + i] = 3 * e1 - 3 * e2 + e3;
  }
  return out;
}

/**
 * Hull moving average: `WMA(2*WMA(n/2) - WMA(n), sqrt(n))`. Designed to track
 * price closely with much less lag than a same-period SMA/EMA while
 * remaining smooth.
 */
export function hullMA(values: readonly number[], period: number): Series {
  requireNonEmpty(values, 'values');
  requirePositiveInt(period, 'period');
  if (period < 2) throw new QuantError('hullMA requires period >= 2');

  const halfPeriod = Math.max(1, Math.round(period / 2));
  const sqrtPeriod = Math.max(1, Math.round(Math.sqrt(period)));

  const wmaHalf = wma(values, halfPeriod);
  const wmaFull = wma(values, period);

  const raw = filled(values.length);
  for (let i = 0; i < values.length; i += 1) {
    const h = wmaHalf[i];
    const f = wmaFull[i];
    if (h !== null && f !== null) raw[i] = 2 * h - f;
  }

  const { offset, values: rawValues } = trimLeadingNulls(raw);
  const hull = wma(rawValues, sqrtPeriod);
  return realign(values.length, offset, hull);
}
