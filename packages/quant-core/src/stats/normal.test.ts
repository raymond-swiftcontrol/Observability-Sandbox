import { describe, expect, it } from 'vitest';
import { QuantError } from '../utils.js';
import { normalCdf, normalInverseCdf, normalPdf } from './normal.js';

describe('normalPdf', () => {
  it('matches the known standard normal density at 0', () => {
    expect(normalPdf(0)).toBeCloseTo(0.3989422804, 8);
  });
});

describe('normalCdf', () => {
  it('is 0.5 at 0', () => {
    // The erfc approximation underneath has ~1.2e-7 fractional error, so match that precision.
    expect(normalCdf(0)).toBeCloseTo(0.5, 6);
  });

  it('matches well-known reference values', () => {
    expect(normalCdf(1.96)).toBeCloseTo(0.975, 3);
    expect(normalCdf(-1.96)).toBeCloseTo(0.025, 3);
    expect(normalCdf(1)).toBeCloseTo(0.8413447, 6);
  });

  it('approaches 0 and 1 in the tails', () => {
    expect(normalCdf(-10)).toBeCloseTo(0, 8);
    expect(normalCdf(10)).toBeCloseTo(1, 8);
  });
});

describe('normalInverseCdf', () => {
  it('round-trips through normalCdf', () => {
    for (const p of [0.001, 0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99, 0.999]) {
      const z = normalInverseCdf(p);
      expect(normalCdf(z)).toBeCloseTo(p, 6);
    }
  });

  it('matches the well-known 1.959964 for p=0.975', () => {
    expect(normalInverseCdf(0.975)).toBeCloseTo(1.959964, 4);
  });

  it('throws for p outside (0, 1)', () => {
    expect(() => normalInverseCdf(0)).toThrow(QuantError);
    expect(() => normalInverseCdf(1)).toThrow(QuantError);
    expect(() => normalInverseCdf(-0.1)).toThrow(QuantError);
  });
});
