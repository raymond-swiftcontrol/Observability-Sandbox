/**
 * Drawdown analysis over an equity curve (a series of portfolio values or
 * cumulative-return index levels, not returns).
 */
import { QuantError, requireNonEmpty } from '../utils.js';

export interface MaxDrawdownResult {
  /** Most negative drawdown, expressed as a fraction (e.g. -0.23 = -23%). */
  readonly maxDrawdown: number;
  readonly peakIndex: number;
  readonly troughIndex: number;
  /** Index where equity first recovers to the pre-drawdown peak, or null if it never does within the series. */
  readonly recoveryIndex: number | null;
  /** Bars from peak to trough. */
  readonly drawdownDuration: number;
  /** Bars from trough back to recovery, or null if it never recovers. */
  readonly recoveryDuration: number | null;
}

/**
 * Finds the single worst peak-to-trough decline. O(n): tracks the running
 * peak and the worst drawdown seen so far in one pass, then does a second
 * bounded pass only to find the recovery point after the identified trough.
 */
export function maxDrawdown(equityCurve: readonly number[]): MaxDrawdownResult {
  requireNonEmpty(equityCurve, 'equityCurve');
  if (equityCurve.length === 1) {
    return {
      maxDrawdown: 0,
      peakIndex: 0,
      troughIndex: 0,
      recoveryIndex: 0,
      drawdownDuration: 0,
      recoveryDuration: 0,
    };
  }

  let peak = equityCurve[0] as number;
  let peakIndex = 0;
  let worstDrawdown = 0;
  let worstPeakIndex = 0;
  let worstTroughIndex = 0;

  for (let i = 0; i < equityCurve.length; i += 1) {
    const v = equityCurve[i] as number;
    if (v > peak) {
      peak = v;
      peakIndex = i;
    }
    const dd = peak === 0 ? 0 : (v - peak) / peak;
    if (dd < worstDrawdown) {
      worstDrawdown = dd;
      worstPeakIndex = peakIndex;
      worstTroughIndex = i;
    }
  }

  const peakValue = equityCurve[worstPeakIndex] as number;
  let recoveryIndex: number | null = null;
  for (let i = worstTroughIndex; i < equityCurve.length; i += 1) {
    if ((equityCurve[i] as number) >= peakValue) {
      recoveryIndex = i;
      break;
    }
  }

  return {
    maxDrawdown: worstDrawdown,
    peakIndex: worstPeakIndex,
    troughIndex: worstTroughIndex,
    recoveryIndex,
    drawdownDuration: worstTroughIndex - worstPeakIndex,
    recoveryDuration: recoveryIndex === null ? null : recoveryIndex - worstTroughIndex,
  };
}

/** Drawdown at every point, always <= 0. Named for the classic underwater-equity chart. */
export function underwaterSeries(equityCurve: readonly number[]): number[] {
  requireNonEmpty(equityCurve, 'equityCurve');
  const out: number[] = [];
  let peak = equityCurve[0] as number;
  for (const v of equityCurve) {
    if (v > peak) peak = v;
    out.push(peak === 0 ? 0 : (v - peak) / peak);
  }
  return out;
}

/**
 * Ulcer Index: RMS of the underwater series, in percent. Unlike max
 * drawdown, it penalises the depth *and duration* of every drawdown, not just
 * the single worst one.
 */
export function ulcerIndex(equityCurve: readonly number[]): number {
  requireNonEmpty(equityCurve, 'equityCurve');
  const underwater = underwaterSeries(equityCurve);
  let sumSq = 0;
  for (const dd of underwater) sumSq += (dd * 100) ** 2;
  return Math.sqrt(sumSq / underwater.length);
}

/** Guard used throughout performance/ so a degenerate series raises loudly instead of returning Infinity. */
export function requireAtLeastTwo(values: readonly number[], label: string): void {
  requireNonEmpty(values, label);
  if (values.length < 2) throw new QuantError(`${label} requires at least 2 values`);
}
