import { describe, expect, it } from 'vitest';
import { QuantError } from '../utils.js';
import { ewmaVolatility } from './ewma.js';

describe('ewmaVolatility', () => {
  it('seeds with |returns[0]| and follows the RiskMetrics recurrence', () => {
    const returns = [0.02, -0.01, 0.03, 0.005];
    const lambda = 0.94;
    const result = ewmaVolatility(returns, lambda);

    expect(result[0]).toBeCloseTo(Math.abs(returns[0] as number), 12);

    let variance = (returns[0] as number) ** 2;
    for (let i = 1; i < returns.length; i += 1) {
      variance = lambda * variance + (1 - lambda) * (returns[i] as number) ** 2;
      expect(result[i]).toBeCloseTo(Math.sqrt(variance), 12);
    }
  });

  it('reacts faster to a volatility spike with a lower lambda', () => {
    const returns = [0.001, 0.001, 0.001, 0.001, 0.001, 0.2];
    const reactive = ewmaVolatility(returns, 0.7);
    const smooth = ewmaVolatility(returns, 0.97);
    expect(reactive[5] as number).toBeGreaterThan(smooth[5] as number);
  });

  it('throws for lambda outside (0, 1)', () => {
    expect(() => ewmaVolatility([0.01], 0)).toThrow(QuantError);
    expect(() => ewmaVolatility([0.01], 1)).toThrow(QuantError);
  });

  it('throws on an empty array', () => {
    expect(() => ewmaVolatility([])).toThrow(QuantError);
  });
});
