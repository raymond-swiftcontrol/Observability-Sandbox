/**
 * Trade-level (as opposed to return-series-level) performance metrics. Each
 * takes an array of individual trade P&Ls, one entry per closed trade — not
 * periodic returns.
 */
import { requireNonEmpty, safeDiv } from '../utils.js';

/** Fraction of trades with P&L > 0. Break-even trades (exactly 0) count as neither win nor loss. */
export function winRate(tradePnls: readonly number[]): number {
  requireNonEmpty(tradePnls, 'tradePnls');
  const wins = tradePnls.filter((p) => p > 0).length;
  return wins / tradePnls.length;
}

/**
 * Gross profit / gross loss. `Infinity` when there are profits and zero
 * losses (a genuinely unbounded ratio, distinct from the no-trades or
 * all-flat case, which return the neutral value 1 and 0 respectively via the
 * checks below).
 */
export function profitFactor(tradePnls: readonly number[]): number {
  requireNonEmpty(tradePnls, 'tradePnls');
  let grossProfit = 0;
  let grossLoss = 0;
  for (const p of tradePnls) {
    if (p > 0) grossProfit += p;
    else grossLoss += -p;
  }
  if (grossLoss === 0) return grossProfit > 0 ? Number.POSITIVE_INFINITY : 0;
  return grossProfit / grossLoss;
}

/** Average P&L per trade, in the same units as the input. */
export function expectancy(tradePnls: readonly number[]): number {
  requireNonEmpty(tradePnls, 'tradePnls');
  let total = 0;
  for (const p of tradePnls) total += p;
  return total / tradePnls.length;
}

/**
 * Average win / |average loss| — how much a typical winner pays relative to
 * a typical loser, independent of how often each occurs (that's `winRate`).
 * 0-safe when there are no losing trades to divide by.
 */
export function payoffRatio(tradePnls: readonly number[]): number {
  requireNonEmpty(tradePnls, 'tradePnls');
  const wins = tradePnls.filter((p) => p > 0);
  const losses = tradePnls.filter((p) => p < 0);
  if (losses.length === 0) return wins.length > 0 ? Number.POSITIVE_INFINITY : 0;
  const avgWin = wins.length === 0 ? 0 : wins.reduce((a, b) => a + b, 0) / wins.length;
  const avgLoss = Math.abs(losses.reduce((a, b) => a + b, 0) / losses.length);
  return safeDiv(avgWin, avgLoss, 0);
}
