import { describe, expect, it } from 'vitest';
import { QuantError } from '../utils.js';
import { kurtosisPopulation, skewness } from '../stats/descriptive.js';
import {
  annualizedVolatility,
  cagr,
  calmarRatio,
  deflatedSharpeRatio,
  downsideDeviation,
  omegaRatio,
  probabilisticSharpeRatio,
  sharpeRatio,
  sortinoRatio,
  tailRatio,
  totalReturn,
} from './returns.js';

describe('totalReturn / cagr', () => {
  it('compounds correctly over a known series', () => {
    // +10%, +10%, -10%: (1.1*1.1*0.9) - 1 = 0.089
    const returns = [0.1, 0.1, -0.1];
    expect(totalReturn(returns)).toBeCloseTo(0.089, 10);
  });

  it('cagr on a doubling over exactly 2 years (252*2 daily periods) is close to sqrt(2)-1', () => {
    const periodsPerYear = 252;
    const n = periodsPerYear * 2;
    const dailyReturn = 2 ** (1 / n) - 1; // engineered so the product compounds to exactly 2x
    const returns = new Array(n).fill(dailyReturn);
    expect(cagr(returns, periodsPerYear)).toBeCloseTo(Math.sqrt(2) - 1, 6);
  });
});

describe('sharpeRatio', () => {
  it('matches a hand-computable value for a simple alternating series', () => {
    // returns: +2%, -1%, +2%, -1%, ... mean = 0.5%, sample stddev over [0.02,-0.01,...]
    const returns = [0.02, -0.01, 0.02, -0.01, 0.02, -0.01];
    const periodsPerYear = 252;
    const result = sharpeRatio(returns, 0, periodsPerYear);
    // Independently compute expected via the same population formulas used in the implementation.
    const m = returns.reduce((a, b) => a + b, 0) / returns.length;
    const variance =
      returns.reduce((acc, r) => acc + (r - m) ** 2, 0) / (returns.length - 1);
    const expected = (m * periodsPerYear) / (Math.sqrt(variance) * Math.sqrt(periodsPerYear));
    expect(result).toBeCloseTo(expected, 10);
  });

  it('returns 0, not Infinity, for a zero-variance (constant) return series', () => {
    const returns = [0.01, 0.01, 0.01, 0.01];
    expect(sharpeRatio(returns, 0, 252)).toBe(0);
  });

  it('handles a flat-zero series without NaN', () => {
    expect(sharpeRatio([0, 0, 0, 0], 0, 252)).toBe(0);
  });

  it('throws on a single-element series (undefined sample stddev)', () => {
    expect(() => sharpeRatio([0.01], 0, 252)).toThrow(QuantError);
  });
});

describe('sortinoRatio and downsideDeviation', () => {
  it('downsideDeviation ignores upside moves entirely', () => {
    const allUp = [0.05, 0.03, 0.02, 0.04];
    expect(downsideDeviation(allUp, 0, 252)).toBe(0);
  });

  it('sortino is 0-safe when there is no downside at all', () => {
    const allUp = [0.05, 0.03, 0.02, 0.04];
    expect(sortinoRatio(allUp, 0, 252)).toBe(0);
  });

  it('is positive for a series with more upside than downside relative to MAR', () => {
    const returns = [0.05, -0.01, 0.04, -0.01, 0.03];
    expect(sortinoRatio(returns, 0, 252)).toBeGreaterThan(0);
  });
});

describe('calmarRatio', () => {
  it('is 0-safe with no drawdown', () => {
    expect(calmarRatio([0.01, 0.01, 0.01], 252)).toBe(0);
  });

  it('is positive for a profitable series with some drawdown', () => {
    const returns = [0.05, -0.02, 0.03, -0.01, 0.04];
    expect(calmarRatio(returns, 252)).toBeGreaterThan(0);
  });
});

describe('omegaRatio', () => {
  it('is Infinity when there are gains and zero losses', () => {
    expect(omegaRatio([0.01, 0.02, 0.03], 0)).toBe(Number.POSITIVE_INFINITY);
  });

  it('is 1 for a perfectly flat series at the threshold', () => {
    expect(omegaRatio([0, 0, 0], 0)).toBe(1);
  });

  it('is greater than 1 when gains outweigh losses', () => {
    expect(omegaRatio([0.05, -0.01, 0.05, -0.01], 0)).toBeGreaterThan(1);
  });
});

describe('tailRatio', () => {
  it('is 0-safe and finite for a well-behaved series', () => {
    const returns = [0.01, -0.02, 0.03, -0.01, 0.02, -0.03, 0.01, -0.01, 0.02, -0.02];
    expect(Number.isFinite(tailRatio(returns))).toBe(true);
  });
});

describe('probabilisticSharpeRatio / deflatedSharpeRatio', () => {
  it('PSR is close to 0.5 when the observed Sharpe equals the benchmark', () => {
    const psr = probabilisticSharpeRatio(0.1, 0.1, 100, 0, 3);
    expect(psr).toBeCloseTo(0.5, 6);
  });

  it('PSR increases with a larger sample size for the same observed edge', () => {
    const small = probabilisticSharpeRatio(0.1, 0, 30, 0, 3);
    const large = probabilisticSharpeRatio(0.1, 0, 3000, 0, 3);
    expect(large).toBeGreaterThan(small);
  });

  it('deflatedSharpeRatio is lower than the plain PSR against 0 once multiple trials are accounted for', () => {
    const observedSharpe = 0.15;
    const n = 500;
    const skew = 0;
    const rawKurtosis = 3;
    const plainPsr = probabilisticSharpeRatio(observedSharpe, 0, n, skew, rawKurtosis);
    const dsr = deflatedSharpeRatio(observedSharpe, n, skew, rawKurtosis, 50, 0.01);
    expect(dsr).toBeLessThan(plainPsr);
  });

  it('is consistent with skew/kurtosis computed by the stats module (integration sanity check)', () => {
    const returns = [0.01, -0.02, 0.015, 0.005, -0.01, 0.02, -0.005, 0.01];
    const skew = skewness(returns);
    const rawKurtosis = kurtosisPopulation(returns);
    const psr = probabilisticSharpeRatio(0.05, 0, returns.length, skew, rawKurtosis);
    expect(psr).toBeGreaterThanOrEqual(0);
    expect(psr).toBeLessThanOrEqual(1);
  });
});

describe('annualizedVolatility', () => {
  it('scales sample stddev by sqrt(periodsPerYear)', () => {
    const returns = [0.01, -0.01, 0.02, -0.02, 0.015];
    const daily = annualizedVolatility(returns, 252);
    const monthly = annualizedVolatility(returns, 12);
    expect(daily).toBeGreaterThan(monthly);
  });
});
