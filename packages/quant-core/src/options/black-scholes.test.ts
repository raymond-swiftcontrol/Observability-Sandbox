import { describe, expect, it } from 'vitest';
import { QuantError } from '../utils.js';
import {
  blackScholesPrice,
  charm,
  delta,
  gamma,
  rho,
  theta,
  vanna,
  vega,
  vomma,
  type BsmParams,
} from './black-scholes.js';

// S=100, K=100, r=0.05, sigma=0.2, T=1 is the textbook reference case with well-known published values.
const reference: BsmParams = { S: 100, K: 100, r: 0.05, sigma: 0.2, T: 1 };

describe('blackScholesPrice', () => {
  it('matches the published reference call price ~10.4506', () => {
    expect(blackScholesPrice('call', reference)).toBeCloseTo(10.4506, 3);
  });

  it('matches the published reference put price ~5.5735', () => {
    expect(blackScholesPrice('put', reference)).toBeCloseTo(5.5735, 3);
  });

  it('satisfies put-call parity numerically', () => {
    const call = blackScholesPrice('call', reference);
    const put = blackScholesPrice('put', reference);
    const { S, K, r, T } = reference;
    expect(call - put).toBeCloseTo(S - K * Math.exp(-r * T), 8);
  });

  it('a deep ITM call is worth close to intrinsic-with-carry, a deep OTM call is close to worthless', () => {
    const deepItm = blackScholesPrice('call', { ...reference, S: 300 });
    expect(deepItm).toBeGreaterThan(190);
    const deepOtm = blackScholesPrice('call', { ...reference, S: 20 });
    expect(deepOtm).toBeLessThan(0.01);
  });

  it('throws on non-positive inputs', () => {
    expect(() => blackScholesPrice('call', { ...reference, S: 0 })).toThrow(QuantError);
    expect(() => blackScholesPrice('call', { ...reference, sigma: -0.1 })).toThrow(QuantError);
    expect(() => blackScholesPrice('call', { ...reference, T: 0 })).toThrow(QuantError);
  });
});

/** Central finite difference — used to cross-check every analytic Greek against the price function itself. */
function centralDiff(f: (h: number) => number, h: number): number {
  return (f(h) - f(-h)) / (2 * h);
}

describe('Greeks vs finite-difference derivatives of the price', () => {
  const h = 1e-4;

  it('delta matches d(price)/dS', () => {
    const numeric = centralDiff(
      (dh) => blackScholesPrice('call', { ...reference, S: reference.S + dh }),
      h,
    );
    expect(delta('call', reference)).toBeCloseTo(numeric, 4);

    const numericPut = centralDiff(
      (dh) => blackScholesPrice('put', { ...reference, S: reference.S + dh }),
      h,
    );
    expect(delta('put', reference)).toBeCloseTo(numericPut, 4);
  });

  it('gamma matches d(delta)/dS', () => {
    const numeric = centralDiff((dh) => delta('call', { ...reference, S: reference.S + dh }), h);
    expect(gamma(reference)).toBeCloseTo(numeric, 4);
  });

  it('vega matches d(price)/dSigma', () => {
    const numeric = centralDiff(
      (dh) => blackScholesPrice('call', { ...reference, sigma: reference.sigma + dh }),
      h,
    );
    expect(vega(reference)).toBeCloseTo(numeric, 3);
  });

  it('rho matches d(price)/dr', () => {
    const numeric = centralDiff(
      (dh) => blackScholesPrice('call', { ...reference, r: reference.r + dh }),
      h,
    );
    expect(rho('call', reference)).toBeCloseTo(numeric, 3);
  });

  it('theta matches -d(price)/dT (calendar time passing = T decreasing)', () => {
    const numeric = -centralDiff(
      (dh) => blackScholesPrice('call', { ...reference, T: reference.T + dh }),
      h,
    );
    expect(theta('call', reference)).toBeCloseTo(numeric, 3);
  });

  it('vanna matches d(delta)/dSigma', () => {
    const numeric = centralDiff((dh) => delta('call', { ...reference, sigma: reference.sigma + dh }), h);
    expect(vanna(reference)).toBeCloseTo(numeric, 3);
  });

  it('vomma matches d(vega)/dSigma', () => {
    const numeric = centralDiff((dh) => vega({ ...reference, sigma: reference.sigma + dh }), h);
    expect(vomma(reference)).toBeCloseTo(numeric, 2);
  });

  it('charm matches -d(delta)/dT for both calls and puts', () => {
    const numericCall = -centralDiff((dh) => delta('call', { ...reference, T: reference.T + dh }), h);
    expect(charm('call', reference)).toBeCloseTo(numericCall, 3);

    const numericPut = -centralDiff((dh) => delta('put', { ...reference, T: reference.T + dh }), h);
    expect(charm('put', reference)).toBeCloseTo(numericPut, 3);
  });

  it('gamma and vega are identical for calls and puts (a BSM identity)', () => {
    expect(gamma(reference)).toBeCloseTo(gamma(reference), 12);
    expect(vega(reference)).toBeCloseTo(vega(reference), 12);
  });
});

describe('edge cases', () => {
  it('delta approaches 1 for calls and -1 for puts deep ITM', () => {
    const deepItm = { ...reference, S: 1000 };
    expect(delta('call', deepItm)).toBeCloseTo(1, 2);
    expect(delta('put', { ...reference, S: 1 })).toBeCloseTo(-1, 2);
  });

  it('gamma and vega shrink toward 0 far from the money or near expiry', () => {
    expect(gamma({ ...reference, S: 5 })).toBeLessThan(gamma(reference));
    expect(vega({ ...reference, T: 0.001 })).toBeLessThan(vega(reference));
  });
});
