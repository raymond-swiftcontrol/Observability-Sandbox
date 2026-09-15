/** Metrics comparing a strategy's returns against a benchmark's returns. */
import { QuantError, requirePositiveInt, safeDiv } from '../utils.js';
import { covariance, mean, stddevSample, varianceSample } from '../stats/descriptive.js';
import { cagr } from './returns.js';
import { requireAtLeastTwo } from './drawdown.js';

function checkAligned(a: readonly number[], b: readonly number[]): void {
  requireAtLeastTwo(a, 'returns');
  if (a.length !== b.length) {
    throw new QuantError('strategy and benchmark return series must be the same length');
  }
}

/** Beta: covariance(strategy, benchmark) / variance(benchmark). 0-safe when the benchmark is flat. */
export function beta(returns: readonly number[], benchmarkReturns: readonly number[]): number {
  checkAligned(returns, benchmarkReturns);
  return safeDiv(covariance(returns, benchmarkReturns), varianceSample(benchmarkReturns), 0);
}

/**
 * Jensen's alpha, annualised: the strategy's actual CAGR minus the CAGR
 * predicted by CAPM from its beta and the benchmark's CAGR (plus the
 * risk-free rate).
 */
export function alpha(
  returns: readonly number[],
  benchmarkReturns: readonly number[],
  riskFreeRate: number,
  periodsPerYear: number,
): number {
  checkAligned(returns, benchmarkReturns);
  const b = beta(returns, benchmarkReturns);
  const strategyCagr = cagr(returns, periodsPerYear);
  const benchmarkCagr = cagr(benchmarkReturns, periodsPerYear);
  const predicted = riskFreeRate + b * (benchmarkCagr - riskFreeRate);
  return strategyCagr - predicted;
}

/** Annualised stddev of the return differences (active returns) between strategy and benchmark. */
export function trackingError(
  returns: readonly number[],
  benchmarkReturns: readonly number[],
  periodsPerYear: number,
): number {
  checkAligned(returns, benchmarkReturns);
  requirePositiveInt(periodsPerYear, 'periodsPerYear');
  const active = returns.map((r, i) => r - (benchmarkReturns[i] as number));
  return stddevSample(active) * Math.sqrt(periodsPerYear);
}

/** Annualised active return divided by tracking error. 0-safe when tracking error is 0 (identical to benchmark). */
export function informationRatio(
  returns: readonly number[],
  benchmarkReturns: readonly number[],
  periodsPerYear: number,
): number {
  checkAligned(returns, benchmarkReturns);
  const active = returns.map((r, i) => r - (benchmarkReturns[i] as number));
  const annualizedActive = mean(active) * periodsPerYear;
  const te = trackingError(returns, benchmarkReturns, periodsPerYear);
  return safeDiv(annualizedActive, te, 0);
}
