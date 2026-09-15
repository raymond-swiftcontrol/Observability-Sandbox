/**
 * Black-Scholes-Merton pricing and analytic Greeks for European options on an
 * underlying paying a continuous dividend yield `q` (set q=0 for the plain
 * Black-Scholes case — a non-dividend stock).
 */
import { QuantError, requireFinite } from '../utils.js';
import { normalCdf, normalPdf } from '../stats/normal.js';

export type OptionType = 'call' | 'put';

export interface BsmParams {
  /** Spot price of the underlying. */
  readonly S: number;
  /** Strike price. */
  readonly K: number;
  /** Continuously-compounded risk-free rate, annualised (e.g. 0.05 for 5%). */
  readonly r: number;
  /** Annualised volatility of the underlying's returns (e.g. 0.20 for 20%). */
  readonly sigma: number;
  /** Time to expiry in years (e.g. 0.5 for 6 months). */
  readonly T: number;
  /** Continuous dividend yield, annualised. Defaults to 0. */
  readonly q?: number;
}

interface D1D2 {
  readonly d1: number;
  readonly d2: number;
}

function validate({ S, K, r, sigma, T }: BsmParams): void {
  requireFinite(S, 'S');
  requireFinite(K, 'K');
  requireFinite(r, 'r');
  requireFinite(sigma, 'sigma');
  requireFinite(T, 'T');
  if (S <= 0) throw new QuantError(`S must be positive, got ${S}`);
  if (K <= 0) throw new QuantError(`K must be positive, got ${K}`);
  if (sigma <= 0) throw new QuantError(`sigma must be positive, got ${sigma}`);
  if (T <= 0) throw new QuantError(`T must be positive, got ${T}`);
}

function d1d2(params: BsmParams): D1D2 {
  const { S, K, r, sigma, T } = params;
  const q = params.q ?? 0;
  const sqrtT = Math.sqrt(T);
  const d1 = (Math.log(S / K) + (r - q + 0.5 * sigma * sigma) * T) / (sigma * sqrtT);
  const d2 = d1 - sigma * sqrtT;
  return { d1, d2 };
}

/** BSM price of a European call or put. */
export function blackScholesPrice(type: OptionType, params: BsmParams): number {
  validate(params);
  const { S, K, r, T } = params;
  const q = params.q ?? 0;
  const { d1, d2 } = d1d2(params);
  const discountedS = S * Math.exp(-q * T);
  const discountedK = K * Math.exp(-r * T);
  if (type === 'call') {
    return discountedS * normalCdf(d1) - discountedK * normalCdf(d2);
  }
  return discountedK * normalCdf(-d2) - discountedS * normalCdf(-d1);
}

/** ∂Price/∂S. Positive for calls (0 to 1), negative for puts (-1 to 0). */
export function delta(type: OptionType, params: BsmParams): number {
  validate(params);
  const { T } = params;
  const q = params.q ?? 0;
  const { d1 } = d1d2(params);
  const discount = Math.exp(-q * T);
  return type === 'call' ? discount * normalCdf(d1) : discount * (normalCdf(d1) - 1);
}

/** ∂²Price/∂S² — identical for calls and puts by put-call parity. */
export function gamma(params: BsmParams): number {
  validate(params);
  const { S, sigma, T } = params;
  const q = params.q ?? 0;
  const { d1 } = d1d2(params);
  return (Math.exp(-q * T) * normalPdf(d1)) / (S * sigma * Math.sqrt(T));
}

/**
 * ∂Price/∂σ, per unit (1.00 = 100 vol points) of volatility — divide by 100
 * for the "per vol point" convention many trading desks quote. Identical for
 * calls and puts.
 */
export function vega(params: BsmParams): number {
  validate(params);
  const { S, sigma, T } = params;
  const q = params.q ?? 0;
  const { d1 } = d1d2(params);
  return S * Math.exp(-q * T) * normalPdf(d1) * Math.sqrt(T);
}

/**
 * ∂Price/∂t (calendar time passing, i.e. -∂Price/∂T), per year — divide by
 * 365 for the "per calendar day" convention most platforms display.
 */
export function theta(type: OptionType, params: BsmParams): number {
  validate(params);
  const { S, K, r, sigma, T } = params;
  const q = params.q ?? 0;
  const { d1, d2 } = d1d2(params);
  const discountedS = S * Math.exp(-q * T);
  const discountedK = K * Math.exp(-r * T);
  const decayTerm = -(discountedS * normalPdf(d1) * sigma) / (2 * Math.sqrt(T));
  if (type === 'call') {
    return decayTerm - r * discountedK * normalCdf(d2) + q * discountedS * normalCdf(d1);
  }
  return decayTerm + r * discountedK * normalCdf(-d2) - q * discountedS * normalCdf(-d1);
}

/** ∂Price/∂r, per unit (1.00 = 100 percentage points) of the risk-free rate. */
export function rho(type: OptionType, params: BsmParams): number {
  validate(params);
  const { K, r, T } = params;
  const { d2 } = d1d2(params);
  const discountedK = K * Math.exp(-r * T);
  return type === 'call' ? T * discountedK * normalCdf(d2) : -T * discountedK * normalCdf(-d2);
}

/** ∂²Price/∂S∂σ = ∂Delta/∂σ. Identical for calls and puts. */
export function vanna(params: BsmParams): number {
  validate(params);
  const { sigma, T } = params;
  const q = params.q ?? 0;
  const { d1, d2 } = d1d2(params);
  return (-Math.exp(-q * T) * normalPdf(d1) * d2) / sigma;
}

/** ∂²Price/∂σ² = ∂Vega/∂σ ("volga"). Identical for calls and puts. */
export function vomma(params: BsmParams): number {
  validate(params);
  const { sigma } = params;
  const { d1, d2 } = d1d2(params);
  return vega(params) * ((d1 * d2) / sigma);
}

/**
 * ∂Delta/∂t (calendar time passing, i.e. -∂Delta/∂T) — "delta decay". Per
 * year; divide by 365 for the per-day figure typically displayed.
 */
export function charm(type: OptionType, params: BsmParams): number {
  validate(params);
  const { r, sigma, T } = params;
  const q = params.q ?? 0;
  const { d1, d2 } = d1d2(params);
  const commonTerm =
    -Math.exp(-q * T) *
    normalPdf(d1) *
    ((2 * (r - q) * T - d2 * sigma * Math.sqrt(T)) / (2 * T * sigma * Math.sqrt(T)));
  if (type === 'call') {
    return commonTerm - q * Math.exp(-q * T) * normalCdf(d1);
  }
  return commonTerm + q * Math.exp(-q * T) * normalCdf(-d1);
}
