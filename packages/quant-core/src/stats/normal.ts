/**
 * Standard normal distribution primitives shared by option pricing (Black-
 * Scholes needs Φ and φ) and the probabilistic/deflated Sharpe ratios (which
 * need Φ⁻¹). Implemented from scratch (no runtime deps) with well-known
 * numerical approximations rather than exact series, which is the standard
 * tradeoff for these functions — closed forms don't exist.
 */
import { QuantError } from '../utils.js';

/** Standard normal probability density function. */
export function normalPdf(x: number): number {
  return Math.exp(-(x * x) / 2) / Math.sqrt(2 * Math.PI);
}

/**
 * Complementary error function via the Numerical Recipes (Press et al.)
 * rational Chebyshev approximation — fractional error < 1.2e-7 for all real
 * x, which is ample for financial pricing (inputs are quoted to a handful of
 * significant figures anyway).
 */
function erfc(x: number): number {
  const z = Math.abs(x);
  const t = 1 / (1 + z / 2);
  const ans =
    t *
    Math.exp(
      -z * z -
        1.26551223 +
        t *
          (1.00002368 +
            t *
              (0.37409196 +
                t *
                  (0.09678418 +
                    t *
                      (-0.18628806 +
                        t *
                          (0.27886807 +
                            t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))),
    );
  return x >= 0 ? ans : 2 - ans;
}

/** Standard normal cumulative distribution function, Φ(x). */
export function normalCdf(x: number): number {
  return 0.5 * erfc(-x / Math.SQRT2);
}

/**
 * Inverse standard normal CDF, Φ⁻¹(p) — Peter Acklam's rational
 * approximation, accurate to about 1.15e-9 relative error, refined by one
 * Halley's-method Newton step for full double precision. Needed for the
 * deflated Sharpe ratio's expected-maximum-Sharpe term.
 */
/** Evaluates a polynomial with the given coefficients (highest degree first) at t via Horner's method. */
function horner(coeffs: readonly number[], t: number): number {
  let result = 0;
  for (const c of coeffs) result = result * t + c;
  return result;
}

const ACKLAM_A = [
  -3.969683028665376e1, 2.209460984245205e2, -2.759285104469687e2, 1.38357751867269e2,
  -3.066479806614716e1, 2.506628277459239,
];
const ACKLAM_B = [
  -5.447609879822406e1, 1.615858368580409e2, -1.556989798598866e2, 6.680131188771972e1,
  -1.328068155288572e1, 1,
];
const ACKLAM_C = [
  -7.784894002430293e-3, -3.223964580411365e-1, -2.400758277161838, -2.549732539343734,
  4.374664141464968, 2.938163982698783,
];
const ACKLAM_D = [
  7.784695709041462e-3, 3.224671290700398e-1, 2.445134137142996, 3.754408661907416, 1,
];

export function normalInverseCdf(p: number): number {
  if (p <= 0 || p >= 1) {
    throw new QuantError(`normalInverseCdf requires p in (0, 1), got ${p}`);
  }

  const pLow = 0.02425;
  let x: number;
  if (p < pLow) {
    const q = Math.sqrt(-2 * Math.log(p));
    x = horner(ACKLAM_C, q) / horner(ACKLAM_D, q);
  } else if (p <= 1 - pLow) {
    const q = p - 0.5;
    const r = q * q;
    x = (horner(ACKLAM_A, r) * q) / horner(ACKLAM_B, r);
  } else {
    const q = Math.sqrt(-2 * Math.log(1 - p));
    x = -horner(ACKLAM_C, q) / horner(ACKLAM_D, q);
  }

  // One Halley refinement step brings this from ~1e-9 to full double precision.
  const e = 0.5 * erfc(-x / Math.SQRT2) - p;
  const u = e * Math.sqrt(2 * Math.PI) * Math.exp((x * x) / 2);
  x = x - u / (1 + (x * u) / 2);
  return x;
}
