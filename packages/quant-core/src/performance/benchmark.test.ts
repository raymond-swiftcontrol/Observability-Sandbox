import { describe, expect, it } from 'vitest';
import { alpha, beta, informationRatio, trackingError } from './benchmark.js';

describe('beta', () => {
  it('is 1 when the strategy exactly tracks the benchmark', () => {
    const benchmark = [0.01, -0.02, 0.03, 0.005, -0.01];
    expect(beta(benchmark, benchmark)).toBeCloseTo(1, 10);
  });

  it('is 2 when the strategy moves exactly 2x the benchmark', () => {
    const benchmark = [0.01, -0.02, 0.03, 0.005, -0.01];
    const strategy = benchmark.map((r) => r * 2);
    expect(beta(strategy, benchmark)).toBeCloseTo(2, 10);
  });

  it('is 0-safe when the benchmark has zero variance', () => {
    expect(beta([0.01, 0.02, 0.03], [0.01, 0.01, 0.01])).toBe(0);
  });
});

describe('alpha', () => {
  it('is ~0 when the strategy exactly matches CAPM expectations (beta * benchmark)', () => {
    const benchmark = [0.01, 0.02, -0.01, 0.015, 0.005];
    const strategy = benchmark; // beta 1, same series => predicted == actual
    expect(alpha(strategy, benchmark, 0, 252)).toBeCloseTo(0, 6);
  });

  it('is positive when the strategy outperforms its CAPM-predicted return', () => {
    const benchmark = [0.001, 0.001, 0.001, 0.001, 0.001];
    const strategy = benchmark.map((r) => r + 0.001); // consistent outperformance
    expect(alpha(strategy, benchmark, 0, 252)).toBeGreaterThan(0);
  });
});

describe('trackingError / informationRatio', () => {
  it('trackingError is 0 when strategy equals benchmark exactly', () => {
    const benchmark = [0.01, -0.02, 0.03, 0.005, -0.01];
    expect(trackingError(benchmark, benchmark, 252)).toBe(0);
  });

  it('informationRatio is 0-safe when tracking error is 0', () => {
    const benchmark = [0.01, -0.02, 0.03, 0.005, -0.01];
    expect(informationRatio(benchmark, benchmark, 252)).toBe(0);
  });

  it('informationRatio is positive for outperformance with varying active returns', () => {
    const benchmark = [0.001, 0.002, 0.0015, 0.0018, 0.0012];
    // Varying (not constant) outperformance, so tracking error is non-zero and IR is well-defined.
    const strategy = [0.002, 0.0025, 0.0018, 0.003, 0.0016];
    expect(informationRatio(strategy, benchmark, 252)).toBeGreaterThan(0);
  });
});
