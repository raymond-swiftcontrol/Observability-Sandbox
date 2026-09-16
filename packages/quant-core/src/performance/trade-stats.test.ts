import { describe, expect, it } from 'vitest';
import { QuantError } from '../utils.js';
import { expectancy, payoffRatio, profitFactor, winRate } from './trade-stats.js';

describe('winRate', () => {
  it('computes the fraction of positive-P&L trades', () => {
    expect(winRate([10, -5, 10, -5, 10])).toBeCloseTo(0.6, 10);
  });

  it('treats exact break-even trades as neither win nor loss', () => {
    expect(winRate([10, 0, -10])).toBeCloseTo(1 / 3, 10);
  });

  it('throws on an empty array', () => {
    expect(() => winRate([])).toThrow(QuantError);
  });
});

describe('profitFactor', () => {
  it('matches gross profit / gross loss on a known series', () => {
    // profit = 10+20=30, loss = 5+5=10 -> profitFactor = 3
    expect(profitFactor([10, -5, 20, -5])).toBeCloseTo(3, 10);
  });

  it('is Infinity with profits and zero losses', () => {
    expect(profitFactor([10, 20, 5])).toBe(Number.POSITIVE_INFINITY);
  });

  it('is 0 for an all-loss series', () => {
    expect(profitFactor([-10, -5])).toBe(0);
  });
});

describe('expectancy', () => {
  it('is the mean P&L', () => {
    expect(expectancy([10, -5, 10, -5])).toBeCloseTo(2.5, 10);
  });
});

describe('payoffRatio', () => {
  it('matches |average win| / |average loss| on a known series', () => {
    // wins: 10, 20 -> avg 15; losses: -5, -15 -> avg |−10| = 10; ratio 1.5
    expect(payoffRatio([10, -5, 20, -15])).toBeCloseTo(1.5, 10);
  });

  it('is Infinity when there are wins and no losses', () => {
    expect(payoffRatio([10, 20])).toBe(Number.POSITIVE_INFINITY);
  });

  it('is 0 when there are neither wins nor losses', () => {
    expect(payoffRatio([0, 0])).toBe(0);
  });
});
