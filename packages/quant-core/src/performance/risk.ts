/**
 * Loss-tail risk measures over a periodic return series. All returned as
 * positive numbers representing a magnitude of loss (a 5% historical VaR is
 * returned as `0.05`, not `-0.05`) since that is how risk desks quote them
 * and mixing sign conventions across VaR/ES call sites is a common bug.
 */
import { requireNonEmpty } from '../utils.js';
import { mean, quantile, stddevSample } from '../stats/descriptive.js';
import { normalInverseCdf } from '../stats/normal.js';

/**
 * Historical VaR at confidence level `confidence` (e.g. 0.95): the loss at
 * the empirical (1 - confidence) quantile of the return distribution, with no
 * distributional assumption. O(n log n) from the sort in `quantile`.
 */
export function historicalVaR(returns: readonly number[], confidence = 0.95): number {
  requireNonEmpty(returns, 'returns');
  const q = quantile(returns, 1 - confidence);
  return Math.max(0, -q);
}

/** Parametric (Gaussian) VaR: assumes normally-distributed returns, using only mean and stddev. */
export function parametricVaR(returns: readonly number[], confidence = 0.95): number {
  requireNonEmpty(returns, 'returns');
  const m = mean(returns);
  const sd = returns.length >= 2 ? stddevSample(returns) : 0;
  const z = normalInverseCdf(1 - confidence);
  return Math.max(0, -(m + z * sd));
}

/**
 * Historical expected shortfall (CVaR): mean loss *beyond* the VaR threshold
 * — answers "given that we're in the bad tail, how bad on average" rather
 * than VaR's "what's the boundary of the bad tail".
 */
export function expectedShortfall(returns: readonly number[], confidence = 0.95): number {
  requireNonEmpty(returns, 'returns');
  const varThreshold = quantile(returns, 1 - confidence);
  const tail = returns.filter((r) => r <= varThreshold);
  if (tail.length === 0) return Math.max(0, -varThreshold);
  return Math.max(0, -mean(tail));
}
