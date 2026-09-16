import { describe, expect, it } from 'vitest';
import { blackScholesPrice, type BsmParams } from './black-scholes.js';
import { impliedVolatility } from './implied-vol.js';

const base: Omit<BsmParams, 'sigma'> = { S: 100, K: 100, r: 0.05, T: 1 };

describe('impliedVolatility', () => {
  it('recovers the exact volatility used to generate the price (ATM call, Newton path)', () => {
    const truePrice = blackScholesPrice('call', { ...base, sigma: 0.25 });
    const result = impliedVolatility('call', truePrice, base);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.iv).toBeCloseTo(0.25, 5);
      expect(result.method).toBe('newton');
    }
  });

  it('recovers volatility for an OTM put too', () => {
    const params = { ...base, K: 80 };
    const truePrice = blackScholesPrice('put', { ...params, sigma: 0.4 });
    const result = impliedVolatility('put', truePrice, params);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.iv).toBeCloseTo(0.4, 4);
  });

  it('still converges when vega is small (deep ITM, short-dated) rather than diverging', () => {
    const params = { ...base, T: 0.15, K: 75 }; // deep ITM, short-dated: vega is small but non-degenerate
    const truePrice = blackScholesPrice('call', { ...params, sigma: 0.18 });
    const result = impliedVolatility('call', truePrice, params);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.iv).toBeCloseTo(0.18, 2);
  });

  it('returns a typed failure (not a wrong number) for a price violating no-arbitrage bounds', () => {
    // A call can never be worth more than the discounted spot.
    const impossiblePrice = base.S * 2;
    const result = impliedVolatility('call', impossiblePrice, base);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toMatch(/no-arbitrage/);
  });

  it('returns a typed failure for a negative price', () => {
    const result = impliedVolatility('call', -5, base);
    expect(result.ok).toBe(false);
  });

  it('bisection alone (forcing Newton off by giving it 0 iterations) still finds the same answer', () => {
    const truePrice = blackScholesPrice('call', { ...base, sigma: 0.35 });
    const result = impliedVolatility('call', truePrice, base, { maxNewtonIterations: 0 });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.method).toBe('bisection');
      expect(result.iv).toBeCloseTo(0.35, 4);
    }
  });
});
