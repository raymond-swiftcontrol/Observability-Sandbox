/** Moving Average Convergence Divergence: the gap between a fast and slow EMA, plus a signal line on that gap. */
import { QuantError, requireNonEmpty, requirePositiveInt, filled, type Series } from '../utils.js';
import { ema } from './moving-averages.js';
import { realign, trimLeadingNulls } from './_internal.js';

export interface MacdResult {
  readonly macd: Series;
  readonly signal: Series;
  readonly histogram: Series;
}

export function macd(
  values: readonly number[],
  fastPeriod = 12,
  slowPeriod = 26,
  signalPeriod = 9,
): MacdResult {
  requireNonEmpty(values, 'values');
  requirePositiveInt(fastPeriod, 'fastPeriod');
  requirePositiveInt(slowPeriod, 'slowPeriod');
  requirePositiveInt(signalPeriod, 'signalPeriod');
  if (fastPeriod >= slowPeriod) throw new QuantError('fastPeriod must be smaller than slowPeriod');

  const fastEma = ema(values, fastPeriod);
  const slowEma = ema(values, slowPeriod);
  const macdLine = filled(values.length);
  for (let i = 0; i < values.length; i += 1) {
    const f = fastEma[i];
    const s = slowEma[i];
    if (f !== null && s !== null) macdLine[i] = f - s;
  }

  const { offset, values: macdValues } = trimLeadingNulls(macdLine);
  const signalLine = ema(macdValues, signalPeriod);
  const signal = realign(values.length, offset, signalLine);

  const histogram = filled(values.length);
  for (let i = 0; i < values.length; i += 1) {
    const m = macdLine[i];
    const s = signal[i];
    if (m !== null && s !== null) histogram[i] = m - s;
  }

  return { macd: macdLine, signal, histogram };
}
