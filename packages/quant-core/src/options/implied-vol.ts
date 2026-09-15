/**
 * Implied volatility by inverting Black-Scholes on the observed price.
 *
 * Newton-Raphson converges quadratically (a handful of iterations) when it
 * converges, but it can overshoot into negative or absurd volatility when
 * vega is small (deep ITM/OTM, near expiry) or the initial guess is poor. So
 * this never trusts a Newton step blindly: it falls back to bisection, which
 * is guaranteed to converge on any continuous, monotonic function given a
 * valid bracket — and returns a typed failure, never a silently wrong
 * number, when even that can't find one (e.g. the quoted price violates
 * no-arbitrage bounds).
 */
import { blackScholesPrice, vega, type BsmParams, type OptionType } from './black-scholes.js';

export type ImpliedVolResult =
  | { readonly ok: true; readonly iv: number; readonly iterations: number; readonly method: 'newton' | 'bisection' }
  | { readonly ok: false; readonly reason: string };

const MIN_VOL = 1e-6;
const MAX_VOL = 5; // 500%/yr — comfortably past any liquid market's implied vol.

function priceAt(type: OptionType, params: Omit<BsmParams, 'sigma'>, sigma: number): number {
  return blackScholesPrice(type, { ...params, sigma });
}

/** No-arbitrage bounds an option price must lie within, given everything but volatility. */
function noArbitrageBounds(type: OptionType, params: Omit<BsmParams, 'sigma'>): { lower: number; upper: number } {
  const { S, K, r, T } = params;
  const q = params.q ?? 0;
  const discountedS = S * Math.exp(-q * T);
  const discountedK = K * Math.exp(-r * T);
  if (type === 'call') {
    return { lower: Math.max(discountedS - discountedK, 0), upper: discountedS };
  }
  return { lower: Math.max(discountedK - discountedS, 0), upper: discountedK };
}

export interface ImpliedVolOptions {
  readonly tolerance?: number;
  readonly maxNewtonIterations?: number;
  readonly maxBisectionIterations?: number;
  readonly initialGuess?: number;
}

export function impliedVolatility(
  type: OptionType,
  marketPrice: number,
  params: Omit<BsmParams, 'sigma'>,
  options: ImpliedVolOptions = {},
): ImpliedVolResult {
  const tolerance = options.tolerance ?? 1e-8;
  const maxNewtonIterations = options.maxNewtonIterations ?? 50;
  const maxBisectionIterations = options.maxBisectionIterations ?? 200;

  if (!Number.isFinite(marketPrice) || marketPrice < 0) {
    return { ok: false, reason: `marketPrice must be a non-negative finite number, got ${marketPrice}` };
  }
  const { lower, upper } = noArbitrageBounds(type, params);
  // Small epsilon tolerance: prices exactly at the boundary imply 0 or infinite volatility,
  // neither of which is a usable answer, so both are treated as out-of-bounds.
  const eps = 1e-10;
  if (marketPrice <= lower + eps || marketPrice >= upper - eps) {
    return {
      ok: false,
      reason: `marketPrice ${marketPrice} is outside the no-arbitrage bracket (${lower}, ${upper}) for this option`,
    };
  }

  // Brenner-Subrahmanyam initial guess: a closed-form ATM approximation that is a
  // reasonable starting point away from ATM too, keeping Newton's iteration count low.
  const { S, T } = params;
  const fallbackGuess = Math.sqrt((2 * Math.PI) / T) * (marketPrice / S);
  let sigma = options.initialGuess ?? clamp(fallbackGuess, MIN_VOL, MAX_VOL);

  for (let i = 0; i < maxNewtonIterations; i += 1) {
    const price = priceAt(type, params, sigma);
    const diff = price - marketPrice;
    if (Math.abs(diff) < tolerance) {
      return { ok: true, iv: sigma, iterations: i + 1, method: 'newton' };
    }
    const v = vega({ ...params, sigma });
    // Vega too flat to trust the step (deep ITM/OTM or near expiry): stop Newton, fall through to bisection.
    if (v < 1e-10) break;
    const next = sigma - diff / v;
    if (!Number.isFinite(next) || next <= MIN_VOL || next >= MAX_VOL) break;
    sigma = next;
  }

  return bisect(type, marketPrice, params, maxBisectionIterations, tolerance);
}

function bisect(
  type: OptionType,
  marketPrice: number,
  params: Omit<BsmParams, 'sigma'>,
  maxIterations: number,
  tolerance: number,
): ImpliedVolResult {
  let lo = MIN_VOL;
  let hi = MAX_VOL;
  const fLo = priceAt(type, params, lo) - marketPrice;
  const fHi = priceAt(type, params, hi) - marketPrice;
  // Price is monotonically increasing in sigma, so a valid bracket must straddle the root.
  if (fLo > 0 || fHi < 0) {
    return { ok: false, reason: 'bisection could not find a bracket containing the root' };
  }

  for (let i = 0; i < maxIterations; i += 1) {
    const mid = (lo + hi) / 2;
    const fMid = priceAt(type, params, mid) - marketPrice;
    if (Math.abs(fMid) < tolerance || hi - lo < 1e-12) {
      return { ok: true, iv: mid, iterations: i + 1, method: 'bisection' };
    }
    if (fMid > 0) hi = mid;
    else lo = mid;
  }
  return { ok: false, reason: `bisection did not converge within ${maxIterations} iterations` };
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}
