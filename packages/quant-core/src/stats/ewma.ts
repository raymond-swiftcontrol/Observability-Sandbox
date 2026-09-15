/**
 * Exponentially-weighted moving average volatility (RiskMetrics style).
 * Weights recent squared returns more heavily than old ones, so it reacts to
 * a volatility regime change far faster than a rolling-window stddev while
 * still being O(n) with O(1) state per step.
 */
import { QuantError, requireNonEmpty, type Series } from '../utils.js';

/**
 * @param returns periodic returns (not prices).
 * @param lambda decay factor in (0, 1); RiskMetrics' standard daily value is
 *   0.94. Higher lambda = longer memory = smoother, slower-reacting series.
 * @returns EWMA volatility (stddev, not variance) aligned to `returns`; the
 *   first element seeds the recursion with |returns[0]| since there is no
 *   prior estimate to decay from.
 */
export function ewmaVolatility(returns: readonly number[], lambda = 0.94): Series {
  requireNonEmpty(returns, 'returns');
  if (lambda <= 0 || lambda >= 1) {
    throw new QuantError(`lambda must be in (0, 1), got ${lambda}`);
  }
  const out: number[] = new Array(returns.length);
  let variance = (returns[0] as number) ** 2;
  out[0] = Math.sqrt(variance);
  for (let i = 1; i < returns.length; i += 1) {
    const r = returns[i] as number;
    variance = lambda * variance + (1 - lambda) * r * r;
    out[i] = Math.sqrt(variance);
  }
  return out;
}
