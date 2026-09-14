/**
 * Broker connectivity contracts — from `openspec/changes/broker-connectivity-sync`
 * and `book.broker_connection` (db/migrations/0007).
 *
 * The spec's read-only requirement — "no order submission path exists for it" —
 * is enforced by the type system here rather than by a runtime check. A
 * `ReadOnlyBrokerAdapter` has no `submitOrder` member at all, so routing an
 * order to one does not compile; a check someone can forget to write, or write
 * after the network call, is not a control.
 */
import { z } from 'zod';
import {
  AuthKind,
  BasisQuality,
  Broker,
  ConnectionState,
  ImportBatchState,
  ImportRowOutcome,
  ProviderKind,
  ReconciliationBreakType,
  Side,
  SyncOutcome,
  SyncResource,
  TransactionKind,
} from './enums.js';
import {
  AccountId,
  ConnectionId,
  CurrencyCode,
  InstrumentId,
  IsoDate,
  Money,
  Price,
  Quantity,
  Ratio,
  Ticker,
  Timestamp,
  UserId,
} from './primitives.js';

/**
 * What a connection is able to do, declared up front. The sync scheduler reads
 * this rather than probing: a broker that cannot supply transaction history has
 * no transaction sync scheduled at all, and its positions are marked
 * `estimated` basis from the start rather than after a failed attempt.
 */
export const BrokerCapabilities = z.object({
  /** The single most consequential flag in this package: see the note above. */
  read_only: z.boolean(),
  resources: z.array(SyncResource).min(1),
  supports_lots: z.boolean().default(false),
  supports_incremental_cursor: z.boolean().default(false),
  /** Oldest history the broker will serve; null means unbounded. */
  history_days: z.number().int().positive().nullable().default(null),
  /** Finest granularity of transaction timestamps, which bounds gap detection. */
  transaction_granularity: z.enum(['tick', 'second', 'day']).default('day'),
  supports_options: z.boolean().default(false),
  supports_crypto: z.boolean().default(false),
  supports_fractional: z.boolean().default(false),
  /** The broker's own declared ceiling; the sync backs off within it. */
  rate_limit_rpm: z.number().int().positive().default(200),
  max_page_size: z.number().int().positive().default(500),
});
export type BrokerCapabilities = z.infer<typeof BrokerCapabilities>;

export const BrokerProvider = z.object({
  broker: Broker,
  display_name: z.string().min(1).max(60),
  kind: ProviderKind,
  auth_kind: AuthKind,
  capabilities: BrokerCapabilities,
  environments: z.array(z.enum(['paper', 'live'])).min(1),
  logo_url: z.string().url().nullable().default(null),
  help_url: z.string().url().nullable().default(null),
  is_enabled: z.boolean().default(true),
});
export type BrokerProvider = z.infer<typeof BrokerProvider>;

/** Per-resource cursor: a failure syncing one resource must not disturb another. */
export const SyncCursor = z.object({
  resource: SyncResource,
  cursor: z.string().max(512).nullable().default(null),
  last_success_at: Timestamp.nullable().default(null),
  last_attempt_at: Timestamp.nullable().default(null),
  last_outcome: SyncOutcome.nullable().default(null),
  /** Phrased for the user, not the operator — the spec asks for actionable text. */
  last_error_message: z.string().max(400).nullable().default(null),
  consecutive_failures: z.number().int().nonnegative().default(0),
});
export type SyncCursor = z.infer<typeof SyncCursor>;

export const BrokerConnection = z.object({
  id: ConnectionId,
  account_id: AccountId,
  user_id: UserId,
  broker: Broker,
  environment: z.enum(['paper', 'live']),
  state: ConnectionState,
  capabilities: BrokerCapabilities,
  /**
   * A pointer into the secret store, never a credential. The redaction list in
   * `@helios/observability` includes `secret_ref` as well, because even the
   * pointer is not something to scatter through logs.
   */
  secret_ref: z.string().min(1).max(200),
  scopes: z.array(z.string().max(48)).default([]),
  cursors: z.array(SyncCursor).default([]),
  last_connected_at: Timestamp.nullable().default(null),
  last_error: z.string().max(400).nullable().default(null),
  last_error_at: Timestamp.nullable().default(null),
  consecutive_failures: z.number().int().nonnegative().default(0),
  /** Set on disconnect; history stays visible, marked as no longer syncing. */
  disconnected_at: Timestamp.nullable().default(null),
  created_at: Timestamp,
  updated_at: Timestamp,
});
export type BrokerConnection = z.infer<typeof BrokerConnection>;

/**
 * A transaction as the broker reported it. `external_id` plus `connection_id` is
 * the idempotency key: re-delivery must not create a second record, and a
 * restatement supersedes rather than mutates, so `supersedes_id` is part of the
 * record rather than an audit table nobody joins.
 */
export const TransactionRecord = z.object({
  id: z.string().uuid(),
  connection_id: ConnectionId.nullable().default(null),
  account_id: AccountId,
  external_id: z.string().min(1).max(128),
  kind: TransactionKind,
  instrument_id: InstrumentId.nullable().default(null),
  /** The raw symbol as the broker spelled it, kept for unresolved instruments. */
  raw_symbol: z.string().max(48).nullable().default(null),
  side: Side.nullable().default(null),
  quantity: Quantity.nullable().default(null),
  price: Price.nullable().default(null),
  amount: Money,
  fees: Money.default('0'),
  currency: CurrencyCode,
  trade_date: IsoDate,
  settlement_date: IsoDate.nullable().default(null),
  occurred_at: Timestamp,
  description: z.string().max(400).nullable().default(null),
  supersedes_id: z.string().uuid().nullable().default(null),
  superseded_at: Timestamp.nullable().default(null),
  /** Manual rows are never destroyed by a sync; this is how they are recognised. */
  is_manual: z.boolean().default(false),
  imported_batch_id: z.string().uuid().nullable().default(null),
  ingested_at: Timestamp,
});
export type TransactionRecord = z.infer<typeof TransactionRecord>;

export const LotSnapshot = z.object({
  external_id: z.string().max(128).nullable().default(null),
  quantity: Quantity,
  entry_price: Price,
  acquired_at: Timestamp,
  basis_quality: BasisQuality,
});
export type LotSnapshot = z.infer<typeof LotSnapshot>;

/**
 * A position as the broker reports it — not the Helios book. Reconciliation
 * compares the two and records a break; the broker's figure never silently
 * overwrites ours.
 */
export const PositionSnapshot = z
  .object({
    connection_id: ConnectionId,
    account_id: AccountId,
    instrument_id: InstrumentId.nullable().default(null),
    raw_symbol: Ticker,
    quantity: Quantity,
    average_price: Price,
    market_value: Money.nullable().default(null),
    unrealized_pnl: Money.nullable().default(null),
    currency: CurrencyCode,
    /**
     * Every displayed cost basis, unrealised P&L and realised P&L derived from
     * an `estimated` lot must carry the indicator. Keeping the quality on the
     * snapshot means a UI cannot render the number without seeing it.
     */
    basis_quality: BasisQuality,
    lots: z.array(LotSnapshot).default([]),
    /** Set when a position change is not explained by any synced transaction. */
    history_incomplete: z.boolean().default(false),
    as_of: Timestamp,
  })
  .superRefine((p, ctx) => {
    if (p.basis_quality === 'sourced' && p.lots.length === 0) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "basis quality 'sourced' requires broker-supplied lots",
        path: ['lots'],
      });
    }
  });
export type PositionSnapshot = z.infer<typeof PositionSnapshot>;

export const BalanceSnapshot = z.object({
  connection_id: ConnectionId,
  account_id: AccountId,
  currency: CurrencyCode,
  cash: Money,
  settled_cash: Money.nullable().default(null),
  buying_power: Money.nullable().default(null),
  margin_loan: Money.nullable().default(null),
  equity: Money.nullable().default(null),
  as_of: Timestamp,
});
export type BalanceSnapshot = z.infer<typeof BalanceSnapshot>;

export const ReconciliationBreak = z.object({
  id: z.string().uuid(),
  connection_id: ConnectionId,
  account_id: AccountId,
  instrument_id: InstrumentId.nullable().default(null),
  break_type: ReconciliationBreakType,
  /** Both sides are recorded; neither is overwritten by the other. */
  broker_value: z.string().max(64),
  book_value: z.string().max(64),
  delta: z.string().max(64),
  resolved_at: Timestamp.nullable().default(null),
  resolution: z.string().max(200).nullable().default(null),
  detected_at: Timestamp,
});
export type ReconciliationBreak = z.infer<typeof ReconciliationBreak>;

export const SyncGap = z.object({
  id: z.string().uuid(),
  connection_id: ConnectionId,
  resource: SyncResource,
  instrument_id: InstrumentId.nullable().default(null),
  from_ts: Timestamp,
  to_ts: Timestamp,
  reason: z.enum(['missing_sequence', 'empty_window', 'unexplained_position_change']),
  detected_at: Timestamp,
  resolved_at: Timestamp.nullable().default(null),
});
export type SyncGap = z.infer<typeof SyncGap>;

// ── File import ──────────────────────────────────────────────────────────────

export const ImportRowPreview = z.object({
  row_number: z.number().int().positive(),
  outcome: ImportRowOutcome,
  /** Why a row was skipped or rejected, in the user's terms. */
  message: z.string().max(200).nullable().default(null),
  parsed: TransactionRecord.partial().nullable().default(null),
});
export type ImportRowPreview = z.infer<typeof ImportRowPreview>;

export const ImportColumnMapping = z.object({
  /** Detected header → canonical field. Correctable before confirmation. */
  columns: z.record(z.string(), z.string()),
  date_format: z.string().max(32).nullable().default(null),
  decimal_separator: z.enum(['.', ',']).default('.'),
  detected_broker: Broker.nullable().default(null),
});
export type ImportColumnMapping = z.infer<typeof ImportColumnMapping>;

/**
 * A batch is created in `previewed` state and writes nothing. The committed
 * result must match the preview, so the per-row outcomes are stored on the
 * preview rather than recomputed at commit time against possibly-changed data.
 */
export const ImportBatch = z
  .object({
    id: z.string().uuid(),
    account_id: AccountId,
    user_id: UserId,
    state: ImportBatchState,
    filename: z.string().max(200),
    byte_size: z.number().int().nonnegative(),
    mapping: ImportColumnMapping,
    row_count: z.number().int().nonnegative(),
    creatable_count: z.number().int().nonnegative(),
    duplicate_count: z.number().int().nonnegative(),
    rejected_count: z.number().int().nonnegative(),
    rows: z.array(ImportRowPreview).default([]),
    created_at: Timestamp,
    previewed_at: Timestamp.nullable().default(null),
    committed_at: Timestamp.nullable().default(null),
    error_message: z.string().max(400).nullable().default(null),
  })
  .superRefine((b, ctx) => {
    if (b.creatable_count + b.duplicate_count + b.rejected_count !== b.row_count) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'row outcomes must account for every row',
        path: ['row_count'],
      });
    }
    if (b.state === 'committed' && b.committed_at === null) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'a committed batch records when it was committed',
        path: ['committed_at'],
      });
    }
  });
export type ImportBatch = z.infer<typeof ImportBatch>;

// ── Adapter interfaces ───────────────────────────────────────────────────────

export interface SyncPage<T> {
  readonly items: readonly T[];
  /** Null when the broker has no more data for this resource. */
  readonly next_cursor: string | null;
}

export interface SyncQuery {
  readonly cursor?: string | null;
  readonly since?: Timestamp;
  readonly limit?: number;
}

/**
 * Everything a connection can do without moving money. Every adapter implements
 * this; a read-only connection implements *only* this.
 */
export interface ReadOnlyBrokerAdapter {
  readonly broker: Broker;
  readonly capabilities: BrokerCapabilities & { readonly read_only: true };

  fetchBalances(connection: BrokerConnection): Promise<readonly BalanceSnapshot[]>;
  fetchPositions(connection: BrokerConnection): Promise<readonly PositionSnapshot[]>;
  fetchTransactions(
    connection: BrokerConnection,
    query: SyncQuery,
  ): Promise<SyncPage<TransactionRecord>>;
  /** Resolves a broker's symbol spelling to a Helios instrument, if it can. */
  resolveSymbol(raw: string): Promise<InstrumentId | null>;
  disconnect(connection: BrokerConnection): Promise<void>;
}

export interface BrokerOrderRequest {
  readonly client_order_id: string;
  readonly instrument_id: InstrumentId;
  readonly side: Side;
  readonly quantity: Quantity;
  readonly limit_price?: Price | null;
  readonly stop_price?: Price | null;
}

export interface BrokerOrderAck {
  readonly broker_order_id: string;
  readonly accepted_at: Timestamp;
}

/**
 * Adds the writing half. The two interfaces are deliberately not related by
 * `extends` on the capabilities field: `read_only: true` versus `read_only:
 * false` makes them mutually exclusive, so a value cannot satisfy both and a
 * `ReadOnlyBrokerAdapter` can never be widened into a trading one by assignment.
 */
export interface TradingBrokerAdapter {
  readonly broker: Broker;
  readonly capabilities: BrokerCapabilities & { readonly read_only: false };

  fetchBalances(connection: BrokerConnection): Promise<readonly BalanceSnapshot[]>;
  fetchPositions(connection: BrokerConnection): Promise<readonly PositionSnapshot[]>;
  fetchTransactions(
    connection: BrokerConnection,
    query: SyncQuery,
  ): Promise<SyncPage<TransactionRecord>>;
  resolveSymbol(raw: string): Promise<InstrumentId | null>;
  disconnect(connection: BrokerConnection): Promise<void>;

  submitOrder(
    connection: BrokerConnection,
    request: BrokerOrderRequest,
  ): Promise<BrokerOrderAck>;
  cancelOrder(connection: BrokerConnection, brokerOrderId: string): Promise<void>;
  replaceOrder(
    connection: BrokerConnection,
    brokerOrderId: string,
    request: BrokerOrderRequest,
  ): Promise<BrokerOrderAck>;
}

export type BrokerAdapter = ReadOnlyBrokerAdapter | TradingBrokerAdapter;

/**
 * The one runtime narrowing that is sound, for code holding a `BrokerAdapter`
 * from a registry. It reads the capability the adapter declares, which is the
 * same bit the type parameter is keyed on.
 */
export function canSubmitOrders(adapter: BrokerAdapter): adapter is TradingBrokerAdapter {
  return adapter.capabilities.read_only === false;
}

/** Cost-basis quality is displayed, never inferred at the point of display. */
export function requiresEstimatedBasisIndicator(quality: BasisQuality): boolean {
  return quality !== 'sourced';
}

export const SyncRunSummary = z.object({
  connection_id: ConnectionId,
  resource: SyncResource,
  outcome: SyncOutcome,
  created_count: z.number().int().nonnegative().default(0),
  duplicate_count: z.number().int().nonnegative().default(0),
  superseded_count: z.number().int().nonnegative().default(0),
  gap_count: z.number().int().nonnegative().default(0),
  next_cursor: z.string().max(512).nullable().default(null),
  started_at: Timestamp,
  finished_at: Timestamp,
  retry_after_seconds: z.number().int().nonnegative().nullable().default(null),
  error_message: z.string().max(400).nullable().default(null),
});
export type SyncRunSummary = z.infer<typeof SyncRunSummary>;

export const ReconciliationSummary = z.object({
  connection_id: ConnectionId,
  breaks: z.array(ReconciliationBreak).default([]),
  tolerance_quantity: Quantity,
  tolerance_ratio: Ratio,
  ran_at: Timestamp,
});
export type ReconciliationSummary = z.infer<typeof ReconciliationSummary>;
