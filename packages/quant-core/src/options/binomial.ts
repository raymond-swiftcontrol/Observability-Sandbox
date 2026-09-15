/**
 * Cox-Ross-Rubinstein binomial tree pricing. The main reason to reach for
 * this over Black-Scholes is early exercise: American options (the default
 * here) can be worth more than their European counterpart, and BSM has no
 * closed form for that. `steps` trades accuracy for O(steps²) time / O(steps)
 * space (the working array is reused in place rather than storing the full
 * triangle) — 200-500 steps is typically enough for basis-point accuracy.
 */
import { QuantError, requireFinite, requirePositiveInt } from '../utils.js';
import type { BsmParams, OptionType } from './black-scholes.js';

export type ExerciseStyle = 'american' | 'european';

export function binomialPrice(
  type: OptionType,
  params: BsmParams,
  steps = 200,
  exerciseStyle: ExerciseStyle = 'american',
): number {
  const { S, K, r, sigma, T } = params;
  const q = params.q ?? 0;
  requireFinite(S, 'S');
  requireFinite(K, 'K');
  requireFinite(r, 'r');
  requireFinite(sigma, 'sigma');
  requireFinite(T, 'T');
  requirePositiveInt(steps, 'steps');
  if (S <= 0 || K <= 0 || sigma <= 0 || T <= 0) {
    throw new QuantError('S, K, sigma and T must all be positive');
  }

  const dt = T / steps;
  const u = Math.exp(sigma * Math.sqrt(dt));
  const d = 1 / u;
  const discount = Math.exp(-r * dt);
  const growth = Math.exp((r - q) * dt);
  const upProbability = (growth - d) / (u - d);
  if (upProbability < 0 || upProbability > 1) {
    // Happens when dt is too coarse relative to (r - q) and sigma (u and d straddle the
    // growth factor incorrectly) — the fix is more steps, which shrinks dt.
    throw new QuantError(
      `binomial risk-neutral probability ${upProbability.toFixed(4)} is outside [0, 1]; try more steps`,
    );
  }

  const intrinsic = (spot: number): number => (type === 'call' ? Math.max(spot - K, 0) : Math.max(K - spot, 0));

  // Terminal payoffs across the `steps + 1` final nodes, indexed by number of up-moves j.
  const values = new Array<number>(steps + 1);
  for (let j = 0; j <= steps; j += 1) {
    const spot = S * u ** j * d ** (steps - j);
    values[j] = intrinsic(spot);
  }

  // Walk backward, collapsing one layer of the tree per step by overwriting `values` in place.
  for (let i = steps - 1; i >= 0; i -= 1) {
    for (let j = 0; j <= i; j += 1) {
      const continuation =
        discount * (upProbability * (values[j + 1] as number) + (1 - upProbability) * (values[j] as number));
      if (exerciseStyle === 'american') {
        const spot = S * u ** j * d ** (i - j);
        values[j] = Math.max(continuation, intrinsic(spot));
      } else {
        values[j] = continuation;
      }
    }
  }

  return values[0] as number;
}
