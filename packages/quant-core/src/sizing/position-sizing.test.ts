import { describe, expect, it } from 'vitest';
import { QuantError } from '../utils.js';
import {
  atrSize,
  equalRiskContributionWeights,
  fixedFractionalSize,
  fixedRiskSize,
  fractionalKellySize,
  volatilityTargetSize,
} from './position-sizing.js';

describe('fixedFractionalSize', () => {
  it('computes quantity from equity fraction and price', () => {
    // 1% of $100,000 = $1,000, at $50/share => 20 shares.
    expect(fixedFractionalSize(100_000, 0.01, 50)).toBeCloseTo(20, 10);
  });

  it('throws for an out-of-range fraction', () => {
    expect(() => fixedFractionalSize(100_000, 0, 50)).toThrow(QuantError);
    expect(() => fixedFractionalSize(100_000, 1.5, 50)).toThrow(QuantError);
  });
});

describe('fixedRiskSize', () => {
  it('sizes so a stop-out loses exactly riskFraction of equity', () => {
    // Risking 1% of $100,000 = $1,000, stop distance $2 => 500 shares, loss at stop = 500*2 = $1,000.
    const qty = fixedRiskSize(100_000, 0.01, 2);
    expect(qty).toBeCloseTo(500, 10);
    expect(qty * 2).toBeCloseTo(1_000, 10);
  });
});

describe('volatilityTargetSize', () => {
  it('scales down quantity as asset volatility rises for the same target', () => {
    const lowVol = volatilityTargetSize(100_000, 0.1, 0.1, 50);
    const highVol = volatilityTargetSize(100_000, 0.1, 0.5, 50);
    expect(lowVol).toBeGreaterThan(highVol);
  });
});

describe('fractionalKellySize', () => {
  it('sizes 0 for a negative-edge bet rather than shorting', () => {
    // win prob 30%, payoff ratio 1 => raw kelly = 0.3 - 0.7/1 = -0.4 -> clamped to 0
    expect(fractionalKellySize(100_000, 0.3, 1, 50)).toBe(0);
  });

  it('respects the fraction cap', () => {
    // win prob 90%, payoff ratio 2 => raw kelly = 0.9 - 0.1/2 = 0.85, capped at 0.25 by default
    const qty = fractionalKellySize(100_000, 0.9, 2, 50, { fractionCap: 0.25 });
    expect(qty).toBeCloseTo((100_000 * 0.25) / 50, 10);
  });

  it('scales down to 0 as drawdown approaches maxDrawdownForZeroSize', () => {
    const base = fractionalKellySize(100_000, 0.6, 2, 50, { fractionCap: 0.5 });
    const guarded = fractionalKellySize(100_000, 0.6, 2, 50, {
      fractionCap: 0.5,
      currentDrawdown: 0.25,
      maxDrawdownForZeroSize: 0.25,
    });
    expect(guarded).toBe(0);
    expect(base).toBeGreaterThan(0);
  });
});

describe('atrSize', () => {
  it('matches fixedRiskSize with stopDistance = atr * atrMultiple', () => {
    const qty = atrSize(100_000, 0.01, 2, 3);
    expect(qty).toBeCloseTo(fixedRiskSize(100_000, 0.01, 6), 10);
  });
});

describe('equalRiskContributionWeights', () => {
  it('splits evenly between two assets with equal vol and no correlation', () => {
    const weights = equalRiskContributionWeights(
      [0.2, 0.2],
      [
        [1, 0],
        [0, 1],
      ],
    );
    expect(weights[0]).toBeCloseTo(0.5, 4);
    expect(weights[1]).toBeCloseTo(0.5, 4);
  });

  it('assigns a lower weight to the higher-volatility asset', () => {
    const weights = equalRiskContributionWeights(
      [0.1, 0.4],
      [
        [1, 0],
        [0, 1],
      ],
    );
    expect(weights[0]).toBeGreaterThan(weights[1] as number);
  });

  it('weights always sum to 1', () => {
    const weights = equalRiskContributionWeights(
      [0.1, 0.2, 0.15],
      [
        [1, 0.3, 0.1],
        [0.3, 1, 0.2],
        [0.1, 0.2, 1],
      ],
    );
    const total = weights.reduce((a, b) => a + b, 0);
    expect(total).toBeCloseTo(1, 6);
  });

  it('throws on a mismatched correlation matrix shape', () => {
    expect(() => equalRiskContributionWeights([0.1, 0.2], [[1]])).toThrow(QuantError);
  });
});
