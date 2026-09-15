/**
 * Position-sizing rules. All return a *quantity* of the underlying (shares,
 * contracts, coins) given an account equity and enough risk context to
 * compute it — never a dollar notional, since converting to quantity at the
 * call site is where unit-mismatch bugs (sizing in dollars, trading in
 * shares) creep in.
 */
import { QuantError, requireFinite } from '../utils.js';

function requirePositive(value: number, label: string): number {
  requireFinite(value, label);
  if (value <= 0) throw new QuantError(`${label} must be positive, got ${value}`);
  return value;
}

/**
 * Fixed-fractional sizing: risk a constant fraction of equity per trade,
 * translated to quantity via the entry price. Ignores the stop distance
 * entirely — use `fixedRiskSize` when you want the fraction to represent
 * risk-to-stop rather than notional exposure.
 */
export function fixedFractionalSize(equity: number, fraction: number, price: number): number {
  requirePositive(equity, 'equity');
  requirePositive(price, 'price');
  if (fraction <= 0 || fraction > 1) {
    throw new QuantError(`fraction must be in (0, 1], got ${fraction}`);
  }
  return (equity * fraction) / price;
}

/**
 * Sizes so that a stop-out at `stopDistance` (in price units, always > 0)
 * away from entry loses exactly `riskFraction` of equity — the standard "risk
 * 1% per trade" rule, correctly translating a fixed dollar risk into a
 * quantity via the stop's price distance rather than the entry price.
 */
export function fixedRiskSize(equity: number, riskFraction: number, stopDistance: number): number {
  requirePositive(equity, 'equity');
  requirePositive(stopDistance, 'stopDistance');
  if (riskFraction <= 0 || riskFraction > 1) {
    throw new QuantError(`riskFraction must be in (0, 1], got ${riskFraction}`);
  }
  return (equity * riskFraction) / stopDistance;
}

/**
 * Volatility targeting: scales quantity so the position's annualised dollar
 * volatility equals `targetVolFraction` of equity, given the asset's own
 * annualised return volatility (as a fraction, e.g. 0.30 for 30%/yr) and
 * price. This is what keeps a low-vol bond ETF and a high-vol altcoin at
 * comparable *risk* contribution rather than comparable notional.
 */
export function volatilityTargetSize(
  equity: number,
  targetVolFraction: number,
  assetAnnualizedVol: number,
  price: number,
): number {
  requirePositive(equity, 'equity');
  requirePositive(price, 'price');
  requirePositive(assetAnnualizedVol, 'assetAnnualizedVol');
  requirePositive(targetVolFraction, 'targetVolFraction');
  const targetDollarVol = equity * targetVolFraction;
  const notional = targetDollarVol / assetAnnualizedVol;
  return notional / price;
}

export interface KellyOptions {
  /** Cap on the raw Kelly fraction actually used, e.g. 0.25 for "quarter Kelly". Default 0.25. */
  readonly fractionCap?: number;
  /**
   * If the account is already in a drawdown deeper than this (as a positive
   * fraction, e.g. 0.15 for -15%), the Kelly fraction is scaled down linearly
   * toward 0 as the drawdown worsens toward `maxDrawdownForZeroSize`. This is
   * the standard defence against Kelly's well-known tendency to compound
   * losses fastest exactly when estimation error is highest.
   */
  readonly currentDrawdown?: number;
  readonly maxDrawdownForZeroSize?: number;
}

/**
 * Fractional Kelly sizing from win probability and payoff ratio (average win
 * / average loss). Full Kelly is `f* = p - (1-p)/b`; this returns
 * `min(f*, 0) -> 0` (Kelly never recommends shorting a positive-edge bet by
 * sizing negative — a negative edge sizes to 0, not a short) scaled by
 * `fractionCap` and, optionally, a drawdown guard.
 */
export function fractionalKellySize(
  equity: number,
  winProbability: number,
  payoffRatio: number,
  price: number,
  options: KellyOptions = {},
): number {
  requirePositive(equity, 'equity');
  requirePositive(price, 'price');
  requirePositive(payoffRatio, 'payoffRatio');
  if (winProbability <= 0 || winProbability >= 1) {
    throw new QuantError(`winProbability must be in (0, 1), got ${winProbability}`);
  }
  const fractionCap = options.fractionCap ?? 0.25;
  const rawKelly = winProbability - (1 - winProbability) / payoffRatio;
  let kelly = Math.max(0, rawKelly);
  kelly = Math.min(kelly, fractionCap);

  const drawdown = options.currentDrawdown ?? 0;
  const maxDD = options.maxDrawdownForZeroSize ?? 0.25;
  if (drawdown > 0 && maxDD > 0) {
    const guardMultiplier = Math.max(0, 1 - drawdown / maxDD);
    kelly *= guardMultiplier;
  }

  return (equity * kelly) / price;
}

/**
 * Sizes so that `atrMultiple` ATRs of adverse movement costs `riskFraction`
 * of equity — a volatility-adaptive variant of `fixedRiskSize` using ATR as
 * the stop-distance proxy instead of a manually chosen stop.
 */
export function atrSize(
  equity: number,
  riskFraction: number,
  atr: number,
  atrMultiple: number,
): number {
  requirePositive(atr, 'atr');
  requirePositive(atrMultiple, 'atrMultiple');
  return fixedRiskSize(equity, riskFraction, atr * atrMultiple);
}

/**
 * Equal risk contribution (ERC / "risk parity") weights across N assets given
 * their volatilities and a correlation matrix: finds weights so every asset
 * contributes the same share of total portfolio risk. Solved by iterative
 * proportional adjustment (a fixed-point iteration converging in practice
 * within a few hundred steps for well-conditioned covariance matrices)
 * rather than a general convex optimiser, since that would need a real
 * QP/NLP dependency — out of place in a zero-dependency package.
 *
 * Returns portfolio *weights* (summing to 1), not quantities: converting to
 * quantities needs per-asset prices and equity, layered on top by the caller.
 */
export function equalRiskContributionWeights(
  volatilities: readonly number[],
  correlationMatrix: readonly (readonly number[])[],
  maxIterations = 500,
  tolerance = 1e-8,
): number[] {
  const n = volatilities.length;
  if (n === 0) throw new QuantError('equalRiskContributionWeights requires at least 1 asset');
  if (correlationMatrix.length !== n || correlationMatrix.some((row) => row.length !== n)) {
    throw new QuantError('correlationMatrix must be n x n matching volatilities.length');
  }
  for (const v of volatilities) requirePositive(v, 'volatility');

  // Covariance matrix from vols + correlation, since ERC operates on risk (covariance), not raw vol.
  const cov: number[][] = Array.from({ length: n }, (_, i) =>
    Array.from({ length: n }, (_, j) => (volatilities[i] as number) * (volatilities[j] as number) * (correlationMatrix[i]![j] as number)),
  );

  let weights = new Array<number>(n).fill(1 / n);

  for (let iter = 0; iter < maxIterations; iter += 1) {
    // Marginal risk contribution of each asset: (Cov * w)_i, and total risk contribution w_i * (Cov*w)_i.
    const covW = cov.map((row) => row.reduce((acc, c, j) => acc + c * (weights[j] as number), 0));
    const riskContrib = weights.map((w, i) => w * (covW[i] as number));
    const totalRisk = riskContrib.reduce((a, b) => a + b, 0);
    if (totalRisk <= 0) break;
    const targetRisk = totalRisk / n;

    // Newton-like multiplicative update: scale each weight inversely to how far its
    // risk contribution is from the equal-risk target, then renormalise to sum to 1.
    const updated = weights.map((w, i) => {
      const contrib = riskContrib[i] as number;
      if (contrib <= 0) return w;
      return w * Math.sqrt(targetRisk / contrib);
    });
    const sumUpdated = updated.reduce((a, b) => a + b, 0);
    const normalized = updated.map((w) => w / sumUpdated);

    let maxDelta = 0;
    for (let i = 0; i < n; i += 1) {
      maxDelta = Math.max(maxDelta, Math.abs((normalized[i] as number) - (weights[i] as number)));
    }
    weights = normalized;
    if (maxDelta < tolerance) break;
  }

  return weights;
}
