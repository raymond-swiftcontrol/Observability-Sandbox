/**
 * Account, portfolio, ledger and position contracts — `book.*`
 * (db/migrations/0007).
 *
 * The book is the one place where a wrong number is a wrong amount of money, so
 * every monetary field here is an exact-decimal scalar rather than a `number`.
 * Field names are the SQL column names; see the note at the top of `market.ts`
 * for why the contracts do not camel-case.
 */
import { z } from 'zod';
import {
  AccountStatus,
  AccountType,
  Broker,
  EntryReason,
  LedgerAccount,
  PositionSide,
  TransferDirection,
} from './enums.js';
import {
  AccountId,
  CurrencyCode,
  InstrumentId,
  IsoDate,
  Money,
  PortfolioId,
  Price,
  Quantity,
  Ratio,
  StrategyId,
  Timestamp,
  UserId,
} from './primitives.js';

export const Account = z.object({
  id: AccountId,
  owner_user_id: UserId,
  name: z.string().min(1).max(80),
  account_type: AccountType,
  status: AccountStatus,
  base_currency: CurrencyCode,
  broker: Broker,
  broker_account_no: z.string().max(48).nullable().default(null),
  is_paper: z.boolean(),
  max_leverage: Ratio,
  day_trade_buying_power_multiple: Ratio,
  pdt_restricted: z.boolean().default(false),
  /**
   * FINRA pattern-day-trader rule: at 4 in a rolling 5 business days on an
   * account under $25k equity, the next day trade is blocked. The counter lives
   * on the account because the pre-trade gate must read it synchronously.
   */
  day_trades_used_5d: z.number().int().min(0).default(0),
  options_level: z.number().int().min(0).max(4).default(0),
  shorting_enabled: z.boolean().default(false),
  crypto_enabled: z.boolean().default(false),
  trading_blocked: z.boolean().default(false),
  trading_blocked_reason: z.string().nullable().default(null),
  opened_at: Timestamp.nullable().default(null),
  closed_at: Timestamp.nullable().default(null),
  created_at: Timestamp,
  updated_at: Timestamp,
});
export type Account = z.infer<typeof Account>;

export const Portfolio = z.object({
  id: PortfolioId,
  account_id: AccountId,
  name: z.string().min(1).max(80),
  description: z.string().nullable().default(null),
  allocated_capital: Money,
  target_volatility: Ratio.nullable().default(null),
  max_drawdown_limit: Ratio.nullable().default(null),
  benchmark_instrument_id: InstrumentId.nullable().default(null),
  is_default: z.boolean().default(false),
  is_active: z.boolean().default(true),
  created_at: Timestamp,
  updated_at: Timestamp,
});
export type Portfolio = z.infer<typeof Portfolio>;

/**
 * T+1 settlement means the same dollar exists in three states at once, and the
 * buying-power figure the order ticket shows is derived from all of them. They
 * are carried separately rather than netted so the app can explain *why* a
 * balance is not spendable.
 */
export const CashBalance = z.object({
  account_id: AccountId,
  currency: CurrencyCode,
  settled: Money,
  unsettled: Money,
  pending_transfer: Money,
  reserved: Money,
  margin_loan: Money,
  buying_power: Money,
  day_trade_buying_power: Money,
  updated_at: Timestamp,
});
export type CashBalance = z.infer<typeof CashBalance>;

export const Position = z
  .object({
    id: z.string().uuid(),
    account_id: AccountId,
    portfolio_id: PortfolioId,
    instrument_id: InstrumentId,
    side: PositionSide,
    /** Always non-negative; direction lives in `side`, mirroring the SQL CHECK. */
    quantity: Quantity,
    avg_entry_price: Price,
    last_price: Price.nullable().default(null),
    marked_at: Timestamp.nullable().default(null),
    market_value: Money.nullable().default(null),
    cost_basis: Money,
    unrealized_pnl: Money.nullable().default(null),
    unrealized_pnl_pct: Ratio.nullable().default(null),
    realized_pnl: Money,
    day_open_quantity: Quantity,
    day_open_price: Price.nullable().default(null),
    day_pnl: Money.nullable().default(null),
    multiplier: Ratio,
    delta_adjusted_qty: Quantity.nullable().default(null),
    opened_by_strategy_id: StrategyId.nullable().default(null),
    opened_at: Timestamp,
    closed_at: Timestamp.nullable().default(null),
    updated_at: Timestamp,
  })
  .superRefine((p, ctx) => {
    // position_flat_iff_zero: a 'flat' row with quantity is a projection bug,
    // and a zero-quantity 'long' row makes every exposure sum wrong.
    const isZero = Number(p.quantity) === 0;
    if ((p.side === 'flat') !== isZero) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "side must be 'flat' exactly when quantity is zero",
        path: ['side'],
      });
    }
  });
export type Position = z.infer<typeof Position>;

/**
 * Tax lots, not netted positions, are the truth for cost basis: realised P&L
 * depends on which lot the sale is matched against, and that is a user
 * preference (FIFO / LIFO / HIFO).
 */
export const PositionLot = z
  .object({
    id: z.string().uuid(),
    position_id: z.string().uuid(),
    account_id: AccountId,
    instrument_id: InstrumentId,
    opening_fill_id: z.string().uuid().nullable().default(null),
    quantity_opened: Quantity,
    quantity_remaining: Quantity,
    entry_price: Price,
    entry_commission: Money,
    opened_at: Timestamp,
    closed_at: Timestamp.nullable().default(null),
    /** US wash-sale rule: a loss is disallowed if repurchased within 30 days. */
    is_wash_sale: z.boolean().default(false),
    holding_period: z.enum(['short_term', 'long_term']).nullable().default(null),
  })
  .superRefine((lot, ctx) => {
    const opened = Number(lot.quantity_opened);
    const remaining = Number(lot.quantity_remaining);
    if (remaining < 0 || remaining > opened) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'quantity_remaining must be within [0, quantity_opened]',
        path: ['quantity_remaining'],
      });
    }
  });
export type PositionLot = z.infer<typeof PositionLot>;

export const LedgerEntry = z.object({
  id: z.string().uuid(),
  transaction_id: z.string().uuid(),
  account_id: AccountId,
  ledger_account: LedgerAccount,
  reason: EntryReason,
  currency: CurrencyCode,
  /** Signed: debits positive, credits negative. The transaction must sum to zero. */
  amount: Money,
  instrument_id: InstrumentId.nullable().default(null),
  quantity: Quantity.nullable().default(null),
  memo: z.string().nullable().default(null),
  occurred_at: Timestamp,
});
export type LedgerEntry = z.infer<typeof LedgerEntry>;

export const Transfer = z.object({
  id: z.string().uuid(),
  account_id: AccountId,
  direction: TransferDirection,
  status: z.enum([
    'requested',
    'pending_review',
    'approved',
    'submitted',
    'settled',
    'rejected',
    'returned',
  ]),
  currency: CurrencyCode,
  amount: Money,
  requested_at: Timestamp,
  settled_at: Timestamp.nullable().default(null),
});
export type Transfer = z.infer<typeof Transfer>;

/**
 * Point-in-time account state. The running statistics (`high_water_mark`,
 * `drawdown`) are stored rather than derived so the mobile performance header
 * renders without scanning the whole history.
 */
export const EquitySnapshot = z.object({
  ts: Timestamp,
  account_id: AccountId,
  portfolio_id: PortfolioId.nullable().default(null),
  equity: Money,
  cash: Money,
  long_market_value: Money,
  short_market_value: Money,
  gross_exposure: Money,
  net_exposure: Money,
  leverage: Ratio.nullable().default(null),
  margin_used: Money,
  maintenance_margin: Money,
  buying_power: Money,
  realized_pnl_day: Money,
  unrealized_pnl: Money,
  fees_day: Money,
  dividends_day: Money,
  return_gross: Ratio.nullable().default(null),
  /** Net of fees and financing — the number a performance claim must be based on. */
  return_net: Ratio.nullable().default(null),
  high_water_mark: Money.nullable().default(null),
  drawdown: Ratio.nullable().default(null),
  positions_count: z.number().int().nonnegative(),
  currency: CurrencyCode,
});
export type EquitySnapshot = z.infer<typeof EquitySnapshot>;

/** A daily performance point as the charts consume it: percentages, no amounts. */
export const PerformancePoint = z.object({
  date: IsoDate,
  return_net: Ratio,
  cumulative_return: Ratio,
  drawdown: Ratio,
});
export type PerformancePoint = z.infer<typeof PerformancePoint>;
