/**
 * Order-management contracts — `oms.*` (db/migrations/0008).
 *
 * The invariants that the SQL enforces with CHECK constraints are re-stated here
 * as refinements rather than left to the database. The order ticket on a phone
 * must be able to tell a user "a stop-limit needs a stop price" without a round
 * trip, and a client that can build an invalid order will eventually send one.
 */
import { z } from 'zod';
import {
  Broker,
  ExecutionAlgo,
  OrderEventType,
  OrderSource,
  OrderStatus,
  OrderType,
  Side,
  TERMINAL_ORDER_STATUSES,
  TimeInForce,
} from './enums.js';
import {
  AccountId,
  Bps,
  FillId,
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
  VenueId,
} from './primitives.js';

/**
 * Client-generated and unique per account forever, which is what makes a retried
 * submit from a flaky mobile connection safe. Constrained to URL-safe characters
 * because it ends up in request paths.
 */
export const ClientOrderId = z
  .string()
  .min(8)
  .max(64)
  .regex(/^[A-Za-z0-9_-]+$/, 'client order id must be URL-safe')
  .brand<'ClientOrderId'>();
export type ClientOrderId = z.infer<typeof ClientOrderId>;

export const BracketRole = z.enum(['entry', 'take_profit', 'stop_loss']);
export type BracketRole = z.infer<typeof BracketRole>;

export const LiquidityFlag = z.enum(['maker', 'taker', 'auction', 'routed']);
export type LiquidityFlag = z.infer<typeof LiquidityFlag>;

/** The order-shape rules shared by the draft (request) and persisted forms. */
const orderShapeRefinement = (
  o: {
    order_type: OrderType;
    time_in_force: TimeInForce;
    limit_price: unknown;
    stop_price: unknown;
    trail_amount: unknown;
    trail_percent: unknown;
    display_quantity: unknown;
    quantity: string | null;
    good_till_date: unknown;
  },
  ctx: z.RefinementCtx,
): void => {
  if (['limit', 'stop_limit', 'limit_on_close'].includes(o.order_type) && o.limit_price == null) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: `${o.order_type} requires a limit price`,
      path: ['limit_price'],
    });
  }
  if (['stop', 'stop_limit'].includes(o.order_type) && o.stop_price == null) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: `${o.order_type} requires a stop price`,
      path: ['stop_price'],
    });
  }
  if (o.order_type === 'trailing_stop' && o.trail_amount == null && o.trail_percent == null) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: 'trailing_stop requires trail_amount or trail_percent',
      path: ['trail_amount'],
    });
  }
  if (o.order_type === 'iceberg') {
    const display = o.display_quantity == null ? null : Number(o.display_quantity);
    const qty = o.quantity == null ? null : Number(o.quantity);
    if (display == null || qty == null || !(display < qty)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'iceberg requires a display_quantity strictly below quantity',
        path: ['display_quantity'],
      });
    }
  }
  if (o.time_in_force === 'gtd' && o.good_till_date == null) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: 'gtd requires good_till_date',
      path: ['good_till_date'],
    });
  }
};

/**
 * What the client sends. Quantity and notional are alternatives — fractional
 * ordering lets a user say "$500 of AAPL" — and exactly one must be supplied,
 * because guessing which the user meant is how someone buys 500 shares.
 */
export const OrderRequest = z
  .object({
    client_order_id: ClientOrderId,
    account_id: AccountId,
    portfolio_id: PortfolioId,
    instrument_id: InstrumentId,
    side: Side,
    order_type: OrderType,
    time_in_force: TimeInForce.default('day'),
    quantity: Quantity.nullable().default(null),
    notional: Money.nullable().default(null),
    limit_price: Price.nullable().default(null),
    stop_price: Price.nullable().default(null),
    trail_amount: Price.nullable().default(null),
    trail_percent: Ratio.nullable().default(null),
    display_quantity: Quantity.nullable().default(null),
    extended_hours: z.boolean().default(false),
    good_till_date: IsoDate.nullable().default(null),
    algo: ExecutionAlgo.default('none'),
    algo_params: z.record(z.unknown()).default({}),
    source: OrderSource.default('mobile'),
    strategy_id: StrategyId.nullable().default(null),
    oco_group_id: z.string().uuid().nullable().default(null),
    bracket_role: BracketRole.nullable().default(null),
  })
  .superRefine((o, ctx) => {
    orderShapeRefinement(o, ctx);
    const hasQty = o.quantity != null && Number(o.quantity) > 0;
    const hasNotional = o.notional != null && Number(o.notional) > 0;
    if (hasQty === hasNotional) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'supply exactly one of quantity or notional',
        path: ['quantity'],
      });
    }
  });
export type OrderRequest = z.infer<typeof OrderRequest>;

export const Order = z
  .object({
    id: OrderId,
    client_order_id: ClientOrderId,
    account_id: AccountId,
    portfolio_id: PortfolioId,
    instrument_id: InstrumentId,
    submitted_by_user_id: UserId.nullable().default(null),
    strategy_id: StrategyId.nullable().default(null),
    source: OrderSource,

    side: Side,
    order_type: OrderType,
    time_in_force: TimeInForce,
    quantity: Quantity,
    limit_price: Price.nullable().default(null),
    stop_price: Price.nullable().default(null),
    trail_amount: Price.nullable().default(null),
    trail_percent: Ratio.nullable().default(null),
    display_quantity: Quantity.nullable().default(null),
    notional: Money.nullable().default(null),
    extended_hours: z.boolean(),
    good_till_date: IsoDate.nullable().default(null),

    status: OrderStatus,
    filled_quantity: Quantity,
    leaves_quantity: Quantity,
    avg_fill_price: Price.nullable().default(null),
    last_fill_price: Price.nullable().default(null),
    last_fill_at: Timestamp.nullable().default(null),

    commission: Money,
    fees: Money,
    /** Mid at the instant of submission; slippage is not reconstructible later. */
    arrival_price: Price.nullable().default(null),
    arrival_mid: Price.nullable().default(null),
    decision_price: Price.nullable().default(null),
    slippage_bps: Bps.nullable().default(null),
    implementation_shortfall_bps: Bps.nullable().default(null),

    algo: ExecutionAlgo,
    algo_params: z.record(z.unknown()).default({}),
    parent_order_id: OrderId.nullable().default(null),
    oco_group_id: z.string().uuid().nullable().default(null),
    bracket_role: BracketRole.nullable().default(null),

    broker: Broker,
    broker_order_id: z.string().max(64).nullable().default(null),
    venue_id: VenueId.nullable().default(null),
    routing_strategy: z.string().max(24).nullable().default(null),

    risk_assessment_id: z.string().uuid().nullable().default(null),
    rejected_reason: z.string().nullable().default(null),
    rejected_code: z.string().max(32).nullable().default(null),

    created_at: Timestamp,
    risk_checked_at: Timestamp.nullable().default(null),
    submitted_at: Timestamp.nullable().default(null),
    acked_at: Timestamp.nullable().default(null),
    first_fill_at: Timestamp.nullable().default(null),
    terminal_at: Timestamp.nullable().default(null),
    updated_at: Timestamp,
    expires_at: Timestamp.nullable().default(null),
  })
  .superRefine((o, ctx) => {
    orderShapeRefinement(o, ctx);
    const qty = Number(o.quantity);
    const filled = Number(o.filled_quantity);
    const leaves = Number(o.leaves_quantity);
    if (filled < 0 || filled > qty) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'filled_quantity must be within [0, quantity]',
        path: ['filled_quantity'],
      });
    }
    // order_leaves_consistent. Compared with a tolerance because quantity is
    // numeric(38,18) and the double comparison here is only a sanity check.
    if (Math.abs(leaves - (qty - filled)) > 1e-9) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'leaves_quantity must equal quantity - filled_quantity',
        path: ['leaves_quantity'],
      });
    }
    const isTerminal = (TERMINAL_ORDER_STATUSES as readonly string[]).includes(o.status);
    if (isTerminal !== (o.terminal_at !== null)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'terminal_at must be set exactly for terminal statuses',
        path: ['terminal_at'],
      });
    }
    if (
      (o.status === 'rejected' || o.status === 'risk_rejected') &&
      (o.rejected_reason === null || o.rejected_reason === '')
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'a rejected order must carry a reason',
        path: ['rejected_reason'],
      });
    }
  });
export type Order = z.infer<typeof Order>;

export const OrderEvent = z.object({
  id: z.number().int().nonnegative(),
  order_id: OrderId,
  sequence: z.number().int().nonnegative(),
  event_type: OrderEventType,
  from_status: OrderStatus.nullable().default(null),
  to_status: OrderStatus,
  quantity: Quantity.nullable().default(null),
  price: Price.nullable().default(null),
  /** Kept verbatim: when a broker's semantics surprise us this is the only record. */
  broker_payload: z.record(z.unknown()).nullable().default(null),
  message: z.string().nullable().default(null),
  trace_id: z.string().regex(/^[0-9a-f]{32}$/).nullable().default(null),
  actor: z.string().max(40).default('system'),
  occurred_at: Timestamp,
  recorded_at: Timestamp,
});
export type OrderEvent = z.infer<typeof OrderEvent>;

export const Fill = z
  .object({
    id: FillId,
    order_id: OrderId,
    account_id: AccountId,
    instrument_id: InstrumentId,
    /** The dedupe key for broker webhook redelivery, which every broker does. */
    broker_exec_id: z.string().max(64).nullable().default(null),
    side: Side,
    quantity: Quantity,
    price: Price,
    gross_amount: Money,
    commission: Money,
    sec_fee: Money,
    taf_fee: Money,
    clearing_fee: Money,
    exchange_fee: Money,
    other_fees: Money,
    net_amount: Money,
    venue_id: VenueId.nullable().default(null),
    liquidity_flag: LiquidityFlag.nullable().default(null),
    nbbo_bid: Price.nullable().default(null),
    nbbo_ask: Price.nullable().default(null),
    effective_spread_bps: Bps.nullable().default(null),
    price_improvement: Money.nullable().default(null),
    trade_date: IsoDate,
    settlement_date: IsoDate.nullable().default(null),
    realized_pnl: Money.nullable().default(null),
    executed_at: Timestamp,
    recorded_at: Timestamp,
    ledger_transaction_id: z.string().uuid().nullable().default(null),
  })
  .superRefine((f, ctx) => {
    if (Number(f.quantity) <= 0) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'fill quantity must be positive',
        path: ['quantity'],
      });
    }
    // fill_net_amount_coherent: fees reduce the proceeds of a sale and increase
    // the cost of a buy. A fill that fails this posts a wrong ledger entry.
    const fees =
      Number(f.commission) +
      Number(f.sec_fee) +
      Number(f.taf_fee) +
      Number(f.clearing_fee) +
      Number(f.exchange_fee) +
      Number(f.other_fees);
    const expected = Number(f.gross_amount) - (f.side === 'buy' ? -1 : 1) * fees;
    if (Math.abs(Number(f.net_amount) - expected) >= 0.01) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'net_amount does not reconcile with gross_amount and itemised fees',
        path: ['net_amount'],
      });
    }
  });
export type Fill = z.infer<typeof Fill>;

/** The pre-trade preview the order ticket renders before the user commits. */
export const OrderPreview = z.object({
  estimated_price: Price,
  estimated_notional: Money,
  estimated_commission: Money,
  estimated_fees: Money,
  buying_power_after: Money,
  margin_requirement: Money,
  warnings: z.array(z.string()).default([]),
  risk_assessment_id: z.string().uuid().nullable().default(null),
});
export type OrderPreview = z.infer<typeof OrderPreview>;

/** A replace changes price or size in place; anything else is a new order. */
export const OrderReplaceRequest = z
  .object({
    order_id: OrderId,
    client_order_id: ClientOrderId,
    quantity: Quantity.nullable().default(null),
    limit_price: Price.nullable().default(null),
    stop_price: Price.nullable().default(null),
    time_in_force: TimeInForce.nullable().default(null),
  })
  .refine(
    (r) =>
      r.quantity !== null ||
      r.limit_price !== null ||
      r.stop_price !== null ||
      r.time_in_force !== null,
    { message: 'a replace must change at least one field' },
  );
export type OrderReplaceRequest = z.infer<typeof OrderReplaceRequest>;
