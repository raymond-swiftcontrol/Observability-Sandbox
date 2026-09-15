import { describe, expect, it } from 'vitest';
import { QuantError } from '../utils.js';
import { maxDrawdown, ulcerIndex, underwaterSeries } from './drawdown.js';

describe('maxDrawdown', () => {
  it('finds the worst peak-to-trough decline on a hand-traced series', () => {
    // Peak at index 2 (120), trough at index 4 (80): drawdown = (80-120)/120 = -1/3.
    // Recovers at index 6 (125 >= 120).
    const curve = [100, 110, 120, 100, 80, 110, 125];
    const result = maxDrawdown(curve);
    expect(result.peakIndex).toBe(2);
    expect(result.troughIndex).toBe(4);
    expect(result.maxDrawdown).toBeCloseTo(-1 / 3, 10);
    expect(result.drawdownDuration).toBe(2);
    expect(result.recoveryIndex).toBe(6);
    expect(result.recoveryDuration).toBe(2);
  });

  it('reports recoveryIndex null when the curve never recovers', () => {
    const curve = [100, 90, 80, 85];
    const result = maxDrawdown(curve);
    expect(result.recoveryIndex).toBeNull();
    expect(result.recoveryDuration).toBeNull();
  });

  it('is 0 for a monotonically increasing curve', () => {
    const result = maxDrawdown([100, 110, 120, 130]);
    expect(result.maxDrawdown).toBe(0);
  });

  it('handles a single-element series without throwing', () => {
    const result = maxDrawdown([100]);
    expect(result.maxDrawdown).toBe(0);
    expect(result.peakIndex).toBe(0);
    expect(result.troughIndex).toBe(0);
  });

  it('throws on an empty array', () => {
    expect(() => maxDrawdown([])).toThrow(QuantError);
  });
});

describe('underwaterSeries', () => {
  it('is always <= 0 and matches maxDrawdown at the trough', () => {
    const curve = [100, 110, 120, 100, 80, 110, 125];
    const underwater = underwaterSeries(curve);
    for (const v of underwater) expect(v).toBeLessThanOrEqual(0);
    expect(underwater[4]).toBeCloseTo(maxDrawdown(curve).maxDrawdown, 10);
  });
});

describe('ulcerIndex', () => {
  it('is 0 for a monotonically increasing curve', () => {
    expect(ulcerIndex([100, 110, 120, 130])).toBe(0);
  });

  it('is positive when there is any drawdown', () => {
    expect(ulcerIndex([100, 110, 120, 100, 80, 110, 125])).toBeGreaterThan(0);
  });
});
