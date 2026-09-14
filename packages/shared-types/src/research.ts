/**
 * Strategy, deployment, signal and backtest contracts — `research.*`
 * (db/migrations/0009) plus the backtest result shapes the quant engine returns.
 */
import { z } from 'zod';
import {
  AssetClass,
  BacktestStatus,
  BarInterval,
  ExecutionAlgo,
  SampleDesignation,
  SignalAction,
  StrategyKind,
  StrategyStatus,
} from './enums.js';
import {
  BacktestId,
  DeploymentId,
  InstrumentId,
  IsoDate,
  Money,
  OrderId,
  PortfolioId,
  Price,
  Quantity,
  Ratio,
  StrategyId,
  Timestamp,
  UserId,
  Weight,
} from './primitives.js';

export const Strategy = z.object({
  id: StrategyId,
  owner_user_id: UserId,
  name: z.string().min(1).max(100),
  slug: z
    .string()
    .min(1)
    .max(100)
    .regex(/^[a-z0-9][a-z0-9-]*$/, 'slug must be lowercase kebab-case'),
  kind: StrategyKind,
  description: z.string().nullable().default(null),
  asset_classes: z.array(AssetClass).min(1),
  bar_interval: BarInterval,
  universe_definition: z.record(z.unknown()).default({}),
  status: StrategyStatus,
  /** Sharing a strategy is opt-in and separate from sharing its results. */
  is_public: z.boolean().default(false),
  is_template: z.boolean().default(false),
  forked_from_id: StrategyId.nullable().default(null),
  tags: z.array(z.string().max(32)).default([]),
  created_at: Timestamp,
  updated_at: Timestamp,
  retired_at: Timestamp.nullable().default(null),
});
export type Strategy = z.infer<typeof Strategy>;

/**
 * Versions are immutable. `content_hash` covers code plus default parameters
 * plus the declared feature set, which is what makes a backtest's provenance
 * checkable rather than merely claimed.
 */
export const StrategyVersion = z
  .object({
    id: z.string().uuid(),
    strategy_id: StrategyId,
    version: z.number().int().positive(),
    content_hash: z.string().regex(/^[0-9a-f]{64}$/, 'content_hash is a sha-256 hex digest'),
    code: z.string().nullable().default(null),
    rule_tree: z.record(z.unknown()).nullable().default(null),
    language: z.string().max(16).default('python'),
    runtime_version: z.string().max(24).default('py3.11'),
    default_parameters: z.record(z.unknown()).default({}),
    /** Declared up front so the engine refuses a strategy reaching for undeclared data. */
    required_features: z.array(z.string().max(64)).default([]),
    max_lookback_bars: z.number().int().positive().default(252),
    changelog: z.string().nullable().default(null),
    created_by: UserId.nullable().default(null),
    created_at: Timestamp,
  })
  .superRefine((v, ctx) => {
    if ((v.code !== null) === (v.rule_tree !== null)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'a version carries exactly one of code or rule_tree',
        path: ['code'],
      });
    }
  });
export type StrategyVersion = z.infer<typeof StrategyVersion>;

export const StrategyParameter = z
  .object({
    key: z.string().max(48),
    label: z.string().max(80),
    data_type: z.enum(['int', 'float', 'bool', 'enum', 'instrument']),
    default_value: z.unknown(),
    min_value: z.number().nullable().default(null),
    max_value: z.number().nullable().default(null),
    step: z.number().nullable().default(null),
    enum_values: z.array(z.string()).nullable().default(null),
    is_sweepable: z.boolean().default(true),
    description: z.string().nullable().default(null),
    display_order: z.number().int().default(0),
  })
  .superRefine((p, ctx) => {
    if (p.min_value !== null && p.max_value !== null && p.max_value < p.min_value) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'max_value must be >= min_value',
        path: ['max_value'],
      });
    }
    if (p.data_type === 'enum' && (p.enum_values === null || p.enum_values.length === 0)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'an enum parameter needs enum_values',
        path: ['enum_values'],
      });
    }
  });
export type StrategyParameter = z.infer<typeof StrategyParameter>;

export const Deployment = z.object({
  id: DeploymentId,
  strategy_version_id: z.string().uuid(),
  portfolio_id: PortfolioId,
  mode: z.enum(['paper', 'live']),
  parameters: z.record(z.unknown()).default({}),
  allocated_capital: Money,
  max_position_count: z.number().int().positive().nullable().default(null),
  max_gross_exposure: Ratio.nullable().default(null),
  max_daily_loss: Money.nullable().default(null),
  /** Live auto-execution is where a strategy bug becomes a money bug: off by default. */
  auto_execute: z.boolean().default(false),
  execution_algo: ExecutionAlgo.default('none'),
  schedule_cron: z.string().max(64).nullable().default(null),
  is_active: z.boolean().default(true),
  paused_at: Timestamp.nullable().default(null),
  paused_reason: z.string().nullable().default(null),
  last_run_at: Timestamp.nullable().default(null),
  next_run_at: Timestamp.nullable().default(null),
  consecutive_errors: z.number().int().nonnegative().default(0),
  deployed_at: Timestamp,
  stopped_at: Timestamp.nullable().default(null),
  created_at: Timestamp,
  updated_at: Timestamp,
});
export type Deployment = z.infer<typeof Deployment>;

export const Signal = z.object({
  ts: Timestamp,
  id: z.string().uuid(),
  deployment_id: DeploymentId,
  strategy_version_id: z.string().uuid(),
  instrument_id: InstrumentId,
  action: SignalAction,
  /**
   * Strength and confidence are distinct on purpose: a strong signal the model
   * is unsure about should size smaller than a weak one it is certain of.
   */
  strength: Ratio.nullable().default(null),
  confidence: Ratio.nullable().default(null),
  target_weight: Weight.nullable().default(null),
  target_quantity: Quantity.nullable().default(null),
  suggested_limit_price: Price.nullable().default(null),
  stop_loss_price: Price.nullable().default(null),
  take_profit_price: Price.nullable().default(null),
  /** Without the inputs the strategy saw, "why did it buy?" is unanswerable. */
  feature_snapshot: z.record(z.number()).nullable().default(null),
  rationale: z.string().nullable().default(null),
  expires_at: Timestamp.nullable().default(null),
  acted_on_at: Timestamp.nullable().default(null),
  order_id: OrderId.nullable().default(null),
  suppressed_reason: z.string().max(48).nullable().default(null),
  bar_ts: Timestamp,
  generated_at: Timestamp,
});
export type Signal = z.infer<typeof Signal>;

/**
 * Backtest assumptions travel with the result, never separately. A tear-sheet
 * without its fee and slippage model is a marketing claim, not a measurement —
 * the trade-sharing spec rejects a share that is missing any of these.
 */
export const BacktestAssumptions = z.object({
  fee_model: z.string().min(1).max(64),
  slippage_model: z.string().min(1).max(64),
  start_date: IsoDate,
  end_date: IsoDate,
  universe_definition: z.record(z.unknown()),
  sample: SampleDesignation,
  initial_capital: Money,
  bar_interval: BarInterval,
  borrow_model: z.string().max(64).nullable().default(null),
});
export type BacktestAssumptions = z.infer<typeof BacktestAssumptions>;

/**
 * Performance statistics as percentages and ratios. No absolute amounts appear
 * here, which is what lets a `returns_only` profile publish the whole object.
 */
export const BacktestMetrics = z.object({
  total_return: Ratio,
  cagr: Ratio,
  volatility_annualised: Ratio,
  sharpe: Ratio,
  sortino: Ratio,
  calmar: Ratio,
  omega: Ratio.nullable().default(null),
  max_drawdown: Ratio,
  max_drawdown_duration_days: z.number().int().nonnegative(),
  ulcer_index: Ratio.nullable().default(null),
  var_95: Ratio.nullable().default(null),
  expected_shortfall_95: Ratio.nullable().default(null),
  beta: Ratio.nullable().default(null),
  alpha: Ratio.nullable().default(null),
  information_ratio: Ratio.nullable().default(null),
  tracking_error: Ratio.nullable().default(null),
  win_rate: Ratio,
  profit_factor: Ratio.nullable().default(null),
  payoff_ratio: Ratio.nullable().default(null),
  expectancy: Ratio.nullable().default(null),
  trade_count: z.number().int().nonnegative(),
  turnover_annualised: Ratio.nullable().default(null),
  exposure: Ratio.nullable().default(null),
  deflated_sharpe: Ratio.nullable().default(null),
});
export type BacktestMetrics = z.infer<typeof BacktestMetrics>;

export const BacktestRun = z.object({
  id: BacktestId,
  strategy_version_id: z.string().uuid(),
  requested_by_user_id: UserId,
  status: BacktestStatus,
  assumptions: BacktestAssumptions,
  parameters: z.record(z.unknown()).default({}),
  metrics: BacktestMetrics.nullable().default(null),
  equity_curve_ref: z.string().max(256).nullable().default(null),
  error_message: z.string().nullable().default(null),
  started_at: Timestamp.nullable().default(null),
  finished_at: Timestamp.nullable().default(null),
  created_at: Timestamp,
});
export type BacktestRun = z.infer<typeof BacktestRun>;
