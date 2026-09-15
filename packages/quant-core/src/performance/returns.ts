/**
 * Return-based performance metrics. Every function takes periodic simple
 * returns (not prices, not an equity curve) plus an explicit
 * `periodsPerYear` for any annualisation — daily equities are ~252, daily
 * crypto is 365, hourly is 252*6.5 or 24*365 depending on the venue, so
 * hardcoding 252 anywhere in this file would silently mis-annualise a
 * strategy on a different sampling frequency.
 */
import { equityCurve, requireNonEmpty, requirePositiveInt, safeDiv } from '../utils.js';
import { mean, quantile, stddevSample } from '../stats/descriptive.js';
import { normalCdf, normalInverseCdf } from '../stats/normal.js';
import { maxDrawdown, requireAtLeastTwo } from './drawdown.js';

/** Compounded total return over the whole series, e.g. 0.25 = +25%. */
export function totalReturn(returns: readonly number[]): number {
  requireNonEmpty(returns, 'returns');
  let level = 1;
  for (const r of returns) level *= 1 + r;
  return level - 1;
}

/**
 * Compound annual growth rate. Undefined (returns 0, the "no growth"
 * baseline) for a series whose compounded level is non-positive, which can
 * happen with a >= -100% period return.
 */
export function cagr(returns: readonly number[], periodsPerYear: number): number {
  requireNonEmpty(returns, 'returns');
  requirePositiveInt(periodsPerYear, 'periodsPerYear');
  const endLevel = 1 + totalReturn(returns);
  if (endLevel <= 0) return -1;
  const years = returns.length / periodsPerYear;
  return endLevel ** (1 / years) - 1;
}

export function annualizedVolatility(returns: readonly number[], periodsPerYear: number): number {
  requireAtLeastTwo(returns, 'returns');
  requirePositiveInt(periodsPerYear, 'periodsPerYear');
  return stddevSample(returns) * Math.sqrt(periodsPerYear);
}

/**
 * Downside deviation: RMS of returns falling short of the minimum acceptable
 * return (MAR), using the full sample size n (not n-1) in the divisor — the
 * standard Sortino-ratio convention, since "no shortfalls observed" should
 * shrink the statistic toward 0, not toward an undefined n-1 with n=1.
 */
export function downsideDeviation(
  returns: readonly number[],
  mar: number,
  periodsPerYear: number,
): number {
  requireNonEmpty(returns, 'returns');
  requirePositiveInt(periodsPerYear, 'periodsPerYear');
  let sumSq = 0;
  for (const r of returns) sumSq += Math.min(r - mar, 0) ** 2;
  return Math.sqrt(sumSq / returns.length) * Math.sqrt(periodsPerYear);
}

/**
 * Annualised Sharpe ratio. Returns 0 — not Infinity — when the return series
 * has zero variance (e.g. a flat or perfectly linear equity curve): there is
 * no risk-adjusted signal to report, and Infinity would poison any
 * downstream ranking or chart.
 */
export function sharpeRatio(
  returns: readonly number[],
  riskFreeRate: number,
  periodsPerYear: number,
): number {
  requireAtLeastTwo(returns, 'returns');
  requirePositiveInt(periodsPerYear, 'periodsPerYear');
  const periodRf = riskFreeRate / periodsPerYear;
  const excess = returns.map((r) => r - periodRf);
  const sd = stddevSample(excess);
  return safeDiv(mean(excess) * periodsPerYear, sd * Math.sqrt(periodsPerYear), 0);
}

/** Sortino ratio: like Sharpe, but only penalises downside deviation. Also 0-safe. */
export function sortinoRatio(
  returns: readonly number[],
  mar: number,
  periodsPerYear: number,
): number {
  requireNonEmpty(returns, 'returns');
  requirePositiveInt(periodsPerYear, 'periodsPerYear');
  const annualizedExcess = (mean(returns) - mar) * periodsPerYear;
  const dd = downsideDeviation(returns, mar, periodsPerYear);
  return safeDiv(annualizedExcess, dd, 0);
}

/** CAGR divided by |max drawdown|. 0-safe when there is no drawdown at all. */
export function calmarRatio(returns: readonly number[], periodsPerYear: number): number {
  requireNonEmpty(returns, 'returns');
  const curve = equityCurve(returns);
  const dd = maxDrawdown(curve).maxDrawdown;
  return safeDiv(cagr(returns, periodsPerYear), Math.abs(dd), 0);
}

/**
 * Omega ratio: sum of gains above `threshold` divided by sum of losses below
 * it. Unlike Sharpe this is not variance-based, so it captures skew. A
 * series with no observations below the threshold has a mathematically
 * unbounded Omega — returned as `Number.POSITIVE_INFINITY` deliberately, since
 * that reflects "no downside occurred", distinct from the zero-variance case
 * (no signal either way) where other ratios here return 0.
 */
export function omegaRatio(returns: readonly number[], threshold = 0): number {
  requireNonEmpty(returns, 'returns');
  let gains = 0;
  let losses = 0;
  for (const r of returns) {
    if (r > threshold) gains += r - threshold;
    else losses += threshold - r;
  }
  if (losses === 0) return gains > 0 ? Number.POSITIVE_INFINITY : 1;
  return gains / losses;
}

/** Ratio of the 95th to the |5th| return percentile — a skew/tail-risk snapshot independent of variance. */
export function tailRatio(returns: readonly number[]): number {
  requireNonEmpty(returns, 'returns');
  const upper = quantile(returns, 0.95);
  const lower = Math.abs(quantile(returns, 0.05));
  return safeDiv(upper, lower, 0);
}

/**
 * Probabilistic Sharpe Ratio (Bailey & López de Prado, 2012): the
 * probability that the *true* Sharpe ratio exceeds a benchmark
 * `benchmarkSharpe`, given the estimation uncertainty from a finite sample of
 * `n` returns and their skew/kurtosis. Sharpe ratios here are per-period
 * (not annualised) since the estimator's variance term is derived per-period.
 *
 * @param observedSharpe per-period Sharpe ratio estimated from the sample.
 * @param benchmarkSharpe per-period Sharpe ratio to test against (often 0).
 * @param n number of return observations behind `observedSharpe`.
 * @param skew sample skewness of the returns.
 * @param rawKurtosis *raw* (non-excess) kurtosis of the returns — i.e.
 *   `kurtosisPopulation` from stats/, not `kurtosisExcess`.
 */
export function probabilisticSharpeRatio(
  observedSharpe: number,
  benchmarkSharpe: number,
  n: number,
  skew: number,
  rawKurtosis: number,
): number {
  requirePositiveInt(n, 'n');
  if (n < 2) throw new Error('probabilisticSharpeRatio requires n >= 2');
  const variance =
    1 -
    skew * observedSharpe +
    ((rawKurtosis - 1) / 4) * observedSharpe ** 2;
  if (variance <= 0) return observedSharpe > benchmarkSharpe ? 1 : 0;
  const z = ((observedSharpe - benchmarkSharpe) * Math.sqrt(n - 1)) / Math.sqrt(variance);
  return normalCdf(z);
}

/**
 * Deflated Sharpe Ratio: the Probabilistic Sharpe Ratio evaluated against
 * `expectedMaxSharpe` — the Sharpe ratio you'd expect to see purely from
 * multiple-testing luck across `numTrials` independent strategy trials with
 * Sharpe-ratio variance `sharpeVarianceAcrossTrials`. This is what makes DSR
 * a defence against backtest overfitting: a strategy that only beats a
 * *single* trial's noise floor, not the noise floor of the whole search you
 * ran to find it, is not deflated enough to trust.
 */
export function deflatedSharpeRatio(
  observedSharpe: number,
  n: number,
  skew: number,
  rawKurtosis: number,
  numTrials: number,
  sharpeVarianceAcrossTrials: number,
): number {
  requirePositiveInt(numTrials, 'numTrials');
  if (sharpeVarianceAcrossTrials < 0) {
    throw new Error('sharpeVarianceAcrossTrials must be >= 0');
  }
  const eulerMascheroni = 0.5772156649015329;
  const expectedMaxSharpe =
    numTrials <= 1
      ? 0
      : Math.sqrt(sharpeVarianceAcrossTrials) *
        ((1 - eulerMascheroni) * normalInverseCdf(1 - 1 / numTrials) +
          eulerMascheroni * normalInverseCdf(1 - 1 / (numTrials * Math.E)));
  return probabilisticSharpeRatio(observedSharpe, expectedMaxSharpe, n, skew, rawKurtosis);
}
