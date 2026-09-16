import { describe, expect, it } from 'vitest';
import { QuantError } from '../utils.js';
import { blackScholesPrice, type BsmParams } from './black-scholes.js';
import { binomialPrice } from './binomial.js';

const reference: BsmParams = { S: 100, K: 100, r: 0.05, sigma: 0.2, T: 1 };

describe('binomialPrice', () => {
  it('converges to the Black-Scholes price for a European option as steps increase', () => {
    const bsmCall = blackScholesPrice('call', reference);
    const binomialCall = binomialPrice('call', reference, 500, 'european');
    expect(binomialCall).toBeCloseTo(bsmCall, 2);

    const bsmPut = blackScholesPrice('put', reference);
    const binomialPut = binomialPrice('put', reference, 500, 'european');
    expect(binomialPut).toBeCloseTo(bsmPut, 2);
  });

  it('an American put is worth at least as much as the European put (early exercise has non-negative value)', () => {
    const americanPut = binomialPrice('put', reference, 300, 'american');
    const europeanPut = binomialPrice('put', reference, 300, 'european');
    expect(americanPut).toBeGreaterThanOrEqual(europeanPut - 1e-9);
  });

  it('an American call on a non-dividend-paying stock equals the European call (never optimal to exercise early)', () => {
    const americanCall = binomialPrice('call', reference, 300, 'american');
    const europeanCall = binomialPrice('call', reference, 300, 'european');
    expect(americanCall).toBeCloseTo(europeanCall, 6);
  });

  it('an American put with a high dividend-adjusted early-exercise incentive is strictly worth more than European', () => {
    // Deep ITM put with a high rate makes early exercise valuable (locking in the strike's interest).
    const deepItmParams: BsmParams = { S: 50, K: 100, r: 0.1, sigma: 0.2, T: 1 };
    const american = binomialPrice('put', deepItmParams, 300, 'american');
    const european = binomialPrice('put', deepItmParams, 300, 'european');
    expect(american).toBeGreaterThan(european + 1e-6);
  });

  it('throws on non-positive inputs', () => {
    expect(() => binomialPrice('call', { ...reference, S: -1 })).toThrow(QuantError);
    expect(() => binomialPrice('call', { ...reference, sigma: 0 })).toThrow(QuantError);
  });
});
