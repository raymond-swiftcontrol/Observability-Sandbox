import { describe, expect, it } from 'vitest';
import { rollingMax, rollingMean, rollingMin, rollingStdDev, rollingVariance } from './rolling.js';

describe('rollingMean', () => {
  it('matches hand-computed values over a simple series', () => {
    const values = [1, 2, 3, 4, 5];
    const result = rollingMean(values, 3);
    expect(result).toEqual([null, null, 2, 3, 4]);
  });

  it('returns all nulls when the series is shorter than the window', () => {
    expect(rollingMean([1, 2], 5)).toEqual([null, null]);
  });

  it('with window 1 equals the series itself', () => {
    expect(rollingMean([5, 6, 7], 1)).toEqual([5, 6, 7]);
  });
});

describe('rollingMin/rollingMax', () => {
  it('tracks the true rolling extremes including a value leaving the window', () => {
    const values = [5, 3, 8, 1, 9, 2];
    // window 3: [5,3,8]->min3,max8 [3,8,1]->min1,max8 [8,1,9]->min1,max9 [1,9,2]->min1,max9
    expect(rollingMin(values, 3)).toEqual([null, null, 3, 1, 1, 1]);
    expect(rollingMax(values, 3)).toEqual([null, null, 8, 8, 9, 9]);
  });

  it('handles a monotonically decreasing series (worst case for the deque)', () => {
    const values = [9, 8, 7, 6, 5, 4];
    expect(rollingMin(values, 3)).toEqual([null, null, 7, 6, 5, 4]);
    expect(rollingMax(values, 3)).toEqual([null, null, 9, 8, 7, 6]);
  });
});

describe('rollingStdDev / rollingVariance', () => {
  it('rollingStdDev(sample) matches direct computation on each window', () => {
    const values = [2, 4, 4, 4, 5, 5, 7, 9];
    const result = rollingStdDev(values, 8, true);
    expect(result[7]).toBeCloseTo(Math.sqrt(32 / 7), 10);
  });

  it('is 0 for a constant window, not NaN', () => {
    const result = rollingStdDev([5, 5, 5, 5, 5], 3, false);
    expect(result[2]).toBe(0);
    expect(result[3]).toBe(0);
    expect(result[4]).toBe(0);
  });

  it('rollingVariance(population) matches variance formula on a known window', () => {
    const values = [2, 4, 4, 4, 5, 5, 7, 9];
    const result = rollingVariance(values, 8, false);
    expect(result[7]).toBeCloseTo(4, 10);
  });
});
