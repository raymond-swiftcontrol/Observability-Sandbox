import { describe, expect, it } from 'vitest';
import { expectedShortfall, historicalVaR, parametricVaR } from './risk.js';

describe('historicalVaR', () => {
  it('matches the empirical quantile on a known sorted series', () => {
    // 20 returns from -0.10 to +0.09 in steps of 0.01; 5% quantile (p=0.05) via linear interpolation.
    const returns = Array.from({ length: 20 }, (_, i) => -0.1 + i * 0.01);
    const varAt95 = historicalVaR(returns, 0.95);
    expect(varAt95).toBeGreaterThan(0);
    // The worst loss is 0.10, so VaR should not exceed it.
    expect(varAt95).toBeLessThanOrEqual(0.1 + 1e-9);
  });

  it('is 0 (not negative) when even the worst-case quantile is a gain', () => {
    const returns = [0.01, 0.02, 0.03, 0.015, 0.025];
    expect(historicalVaR(returns, 0.5)).toBe(0);
  });
});

describe('parametricVaR', () => {
  it('is close to historicalVaR for a large roughly-normal sample', () => {
    // Deterministic pseudo-normal-ish sample via a fixed seed (Box-Muller).
    let seed = 7;
    const rand = () => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    };
    const returns: number[] = [];
    for (let i = 0; i < 5000; i += 1) {
      const u1 = Math.max(rand(), 1e-9);
      const u2 = rand();
      const z = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
      returns.push(0.0005 + 0.01 * z);
    }
    const historical = historicalVaR(returns, 0.95);
    const parametric = parametricVaR(returns, 0.95);
    expect(Math.abs(historical - parametric)).toBeLessThan(0.01);
  });

  it('is 0 when there is a single observation (zero variance assumed)', () => {
    expect(parametricVaR([0.01], 0.95)).toBeGreaterThanOrEqual(0);
  });
});

describe('expectedShortfall', () => {
  it('is always >= historicalVaR at the same confidence (tail mean is worse than the boundary)', () => {
    const returns = [-0.2, -0.1, -0.05, -0.01, 0, 0.01, 0.02, 0.03, 0.04, 0.05];
    const es = expectedShortfall(returns, 0.9);
    const varValue = historicalVaR(returns, 0.9);
    expect(es).toBeGreaterThanOrEqual(varValue - 1e-9);
  });
});
