/**
 * Pre-trade risk, limits and exposure contracts.
 *
 * The pre-trade gate is synchronous and on the critical path of every order, so
 * its verdict shape is deliberately small: a verdict, the breaches that produced
 * it, and enough identifiers to audit the decision afterwards.
 */
import { z } from 'zod';
import {
  RiskEnforcement,
  RiskLimitKind,
  RiskLimitScope,
  RiskVerdict,
  VarMethod,
} from './enums.js';
import {
  AccountId,
  DeploymentId,
  InstrumentId,
  Money,
  OrderId,
  PortfolioId,
  Price,
  Quantity,
  Ratio,
  Timestamp,
} from './primitives.js';

export const RiskLimit = z
  .object({
    id: z.string().uuid(),
    scope: RiskLimitScope,
    /** Exactly one of these is set, matching the scope. */
    account_id: AccountId.nullable().default(null),
    portfolio_id: PortfolioId.nullable().default(null),
    deployment_id: DeploymentId.nullable().default(null),
    instrument_id: InstrumentId.nullable().default(null),
    /** Free-form for the sector / asset-class scopes, which name a bucket not a row. */
    scope_key: z.string().max(48).nullable().default(null),
    kind: RiskLimitKind,
    enforcement: RiskEnforcement.default('hard'),
    /** A ratio for exposure-style limits, an amount for loss-style limits. */
    threshold_ratio: Ratio.nullable().default(null),
    threshold_money: Money.nullable().default(null),
    /** Warn before block: the app can surface an approaching limit. */
    warn_at_pct_of_limit: Ratio.default('0.8'),
    is_active: z.boolean().default(true),
    created_at: Timestamp,
    updated_at: Timestamp,
  })
  .superRefine((l, ctx) => {
    if ((l.threshold_ratio === null) === (l.threshold_money === null)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'a limit carries exactly one of threshold_ratio or threshold_money',
        path: ['threshold_ratio'],
      });
    }
    // Exactly one target must be named, and which field names it depends on the
    // scope. Written as a total record so a new scope value fails to compile.
    const scoped: Readonly<Record<RiskLimitScope, string | null>> = {
      account: l.account_id,
      portfolio: l.portfolio_id,
      deployment: l.deployment_id,
      instrument: l.instrument_id,
      sector: l.scope_key,
      asset_class: l.scope_key,
      desk: l.scope_key,
    };
    if (scoped[l.scope] === null) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `a ${l.scope}-scoped limit must name its ${l.scope}`,
        path: ['scope'],
      });
    }
  });
export type RiskLimit = z.infer<typeof RiskLimit>;

export const RiskBreach = z.object({
  limit_id: z.string().uuid().nullable().default(null),
  kind: RiskLimitKind,
  scope: RiskLimitScope,
  /** Both sides of the comparison, so the message can be rendered client-side. */
  observed: Ratio,
  threshold: Ratio,
  enforcement: RiskEnforcement,
  message: z.string().min(1),
});
export type RiskBreach = z.infer<typeof RiskBreach>;

/**
 * The gate's decision, recorded whether it approved or not. An approval that is
 * never written down cannot be audited after a bad day.
 */
export const RiskAssessment = z.object({
  id: z.string().uuid(),
  order_id: OrderId.nullable().default(null),
  account_id: AccountId,
  portfolio_id: PortfolioId.nullable().default(null),
  verdict: RiskVerdict,
  breaches: z.array(RiskBreach).default([]),
  /** Post-trade projections the gate computed to reach its verdict. */
  projected_gross_exposure: Money.nullable().default(null),
  projected_net_exposure: Money.nullable().default(null),
  projected_leverage: Ratio.nullable().default(null),
  projected_buying_power: Money.nullable().default(null),
  margin_requirement: Money.nullable().default(null),
  kill_switch_engaged: z.boolean().default(false),
  evaluated_at: Timestamp,
  /** Milliseconds; the gate has a latency SLO and this is what measures it. */
  duration_ms: z.number().nonnegative(),
});
export type RiskAssessment = z.infer<typeof RiskAssessment>;

export const VarSnapshot = z.object({
  ts: Timestamp,
  account_id: AccountId,
  portfolio_id: PortfolioId.nullable().default(null),
  method: VarMethod,
  /** 0.95 or 0.99 in practice; stored rather than assumed. */
  confidence: Ratio,
  horizon_days: z.number().int().positive(),
  var_amount: Money,
  var_pct: Ratio,
  expected_shortfall: Money.nullable().default(null),
  expected_shortfall_pct: Ratio.nullable().default(null),
  lookback_days: z.number().int().positive().nullable().default(null),
  simulations: z.number().int().positive().nullable().default(null),
});
export type VarSnapshot = z.infer<typeof VarSnapshot>;

/**
 * Option sensitivities. Kept as ratios rather than money so the same shape
 * serves a single contract and an aggregated book; multiply by notional at the
 * point of display.
 */
export const Greeks = z.object({
  instrument_id: InstrumentId.nullable().default(null),
  as_of: Timestamp,
  delta: Ratio,
  gamma: Ratio,
  theta: Ratio,
  vega: Ratio,
  rho: Ratio,
  /** Second-order: the book-level hedging desk needs these, the ticket does not. */
  vanna: Ratio.nullable().default(null),
  charm: Ratio.nullable().default(null),
  vomma: Ratio.nullable().default(null),
  implied_volatility: Ratio.nullable().default(null),
  underlying_price: Price.nullable().default(null),
});
export type Greeks = z.infer<typeof Greeks>;

export const ExposureBucket = z.object({
  label: z.string().min(1).max(64),
  gross: Money,
  net: Money,
  weight: Ratio,
  quantity: Quantity.nullable().default(null),
});
export type ExposureBucket = z.infer<typeof ExposureBucket>;
