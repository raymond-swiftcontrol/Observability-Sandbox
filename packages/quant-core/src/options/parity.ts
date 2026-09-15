/**
 * Put-call parity: C - P = S e^{-qT} - K e^{-rT}. A cheap, model-free sanity
 * check that a pair of quoted call/put prices (or two model outputs) are
 * mutually consistent — no volatility input required.
 */
import { requireFinite } from '../utils.js';

export interface ParityCheckParams {
  readonly callPrice: number;
  readonly putPrice: number;
  readonly S: number;
  readonly K: number;
  readonly r: number;
  readonly T: number;
  readonly q?: number;
}

export interface ParityCheckResult {
  readonly holds: boolean;
  /** callPrice - putPrice. */
  readonly lhs: number;
  /** S e^{-qT} - K e^{-rT}. */
  readonly rhs: number;
  /** lhs - rhs; 0 when parity holds exactly. */
  readonly difference: number;
}

export function checkPutCallParity(params: ParityCheckParams, tolerance = 1e-6): ParityCheckResult {
  const { callPrice, putPrice, S, K, r, T } = params;
  const q = params.q ?? 0;
  requireFinite(callPrice, 'callPrice');
  requireFinite(putPrice, 'putPrice');
  requireFinite(S, 'S');
  requireFinite(K, 'K');
  requireFinite(r, 'r');
  requireFinite(T, 'T');

  const lhs = callPrice - putPrice;
  const rhs = S * Math.exp(-q * T) - K * Math.exp(-r * T);
  const difference = lhs - rhs;
  return { holds: Math.abs(difference) <= tolerance, lhs, rhs, difference };
}
