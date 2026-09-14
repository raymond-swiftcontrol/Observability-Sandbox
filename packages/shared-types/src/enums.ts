/**
 * Enumerations mirroring the Postgres enum types one-for-one.
 *
 * These are duplicated from SQL rather than generated because the generated
 * option (introspection at build time) makes the TypeScript build depend on a
 * live database. The duplication is held honest by `enums.test.ts`, which parses
 * `db/migrations/*.sql` and asserts member-for-member parity — add a value in SQL
 * without adding it here and that test fails.
 *
 * Ordering matters: it is the SQL declaration order, which is also the sort order
 * Postgres uses for the type, so a query that `ORDER BY status` and a client that
 * sorts by index agree.
 */
import { z } from 'zod';

function sqlEnum<const T extends readonly [string, ...string[]]>(values: T) {
  return z.enum(values as unknown as [T[number], ...T[number][]]);
}

// ── reference (migration 0001, 0003) ─────────────────────────────────────────
export const ASSET_CLASSES = [
  'equity',
  'etf',
  'adr',
  'fund',
  'option',
  'future',
  'future_option',
  'forex',
  'crypto',
  'crypto_perp',
  'index',
  'bond',
  'commodity',
  'warrant',
  'cfd',
] as const;
export const AssetClass = sqlEnum(ASSET_CLASSES);
export type AssetClass = z.infer<typeof AssetClass>;

export const BAR_INTERVALS = [
  '1s',
  '5s',
  '15s',
  '1m',
  '5m',
  '15m',
  '30m',
  '1h',
  '4h',
  '1d',
  '1w',
  '1mo',
] as const;
export const BarInterval = sqlEnum(BAR_INTERVALS);
export type BarInterval = z.infer<typeof BarInterval>;

export const SIDES = ['buy', 'sell'] as const;
export const Side = sqlEnum(SIDES);
export type Side = z.infer<typeof Side>;

export const POSITION_SIDES = ['long', 'short', 'flat'] as const;
export const PositionSide = sqlEnum(POSITION_SIDES);
export type PositionSide = z.infer<typeof PositionSide>;

export const DATA_QUALITIES = ['verified', 'vendor', 'derived', 'estimated', 'suspect'] as const;
export const DataQuality = sqlEnum(DATA_QUALITIES);
export type DataQuality = z.infer<typeof DataQuality>;

export const VENUE_KINDS = [
  'exchange',
  'mtf',
  'ats',
  'dark_pool',
  'ecn',
  'otc',
  'crypto_cex',
  'crypto_dex',
] as const;
export const VenueKind = sqlEnum(VENUE_KINDS);
export type VenueKind = z.infer<typeof VenueKind>;

export const INSTRUMENT_STATUSES = [
  'active',
  'halted',
  'suspended',
  'delisted',
  'pre_listing',
  'expired',
] as const;
export const InstrumentStatus = sqlEnum(INSTRUMENT_STATUSES);
export type InstrumentStatus = z.infer<typeof InstrumentStatus>;

export const OPTION_TYPES = ['call', 'put'] as const;
export const OptionType = sqlEnum(OPTION_TYPES);
export type OptionType = z.infer<typeof OptionType>;

export const EXERCISE_STYLES = ['american', 'european', 'bermudan'] as const;
export const ExerciseStyle = sqlEnum(EXERCISE_STYLES);
export type ExerciseStyle = z.infer<typeof ExerciseStyle>;

export const SETTLEMENT_TYPES = ['physical', 'cash'] as const;
export const SettlementType = sqlEnum(SETTLEMENT_TYPES);
export type SettlementType = z.infer<typeof SettlementType>;

// ── book (migration 0007) ────────────────────────────────────────────────────
export const ACCOUNT_TYPES = [
  'cash',
  'margin',
  'portfolio_margin',
  'ira',
  'roth_ira',
  'paper',
  'simulated',
] as const;
export const AccountType = sqlEnum(ACCOUNT_TYPES);
export type AccountType = z.infer<typeof AccountType>;

export const ACCOUNT_STATUSES = [
  'pending',
  'active',
  'restricted',
  'liquidation_only',
  'closed',
] as const;
export const AccountStatus = sqlEnum(ACCOUNT_STATUSES);
export type AccountStatus = z.infer<typeof AccountStatus>;

export const BROKERS = [
  'internal_sim',
  'alpaca',
  'interactive_brokers',
  'tradier',
  'binance',
  'coinbase',
  'oanda',
  'tastytrade',
] as const;
export const Broker = sqlEnum(BROKERS);
export type Broker = z.infer<typeof Broker>;

export const LEDGER_ACCOUNTS = [
  'cash',
  'settled_cash',
  'unsettled_cash',
  'margin_loan',
  'securities',
  'realized_pnl',
  'unrealized_pnl',
  'commission',
  'fees',
  'interest',
  'dividend',
  'tax_withheld',
  'transfer_in',
  'transfer_out',
  'borrow_fee',
] as const;
export const LedgerAccount = sqlEnum(LEDGER_ACCOUNTS);
export type LedgerAccount = z.infer<typeof LedgerAccount>;

export const ENTRY_REASONS = [
  'fill',
  'commission',
  'regulatory_fee',
  'dividend',
  'interest',
  'margin_interest',
  'borrow_fee',
  'deposit',
  'withdrawal',
  'fx_conversion',
  'corporate_action',
  'adjustment',
  'assignment',
  'exercise',
  'expiration',
] as const;
export const EntryReason = sqlEnum(ENTRY_REASONS);
export type EntryReason = z.infer<typeof EntryReason>;

export const TRANSFER_STATUSES = [
  'requested',
  'pending_review',
  'approved',
  'submitted',
  'settled',
  'rejected',
  'returned',
] as const;
export const TransferStatus = sqlEnum(TRANSFER_STATUSES);
export type TransferStatus = z.infer<typeof TransferStatus>;

export const TRANSFER_DIRECTIONS = ['deposit', 'withdrawal', 'internal'] as const;
export const TransferDirection = sqlEnum(TRANSFER_DIRECTIONS);
export type TransferDirection = z.infer<typeof TransferDirection>;

// ── oms (migration 0008) ─────────────────────────────────────────────────────
export const ORDER_TYPES = [
  'market',
  'limit',
  'stop',
  'stop_limit',
  'trailing_stop',
  'market_on_open',
  'market_on_close',
  'limit_on_close',
  'pegged',
  'iceberg',
] as const;
export const OrderType = sqlEnum(ORDER_TYPES);
export type OrderType = z.infer<typeof OrderType>;

export const TIME_IN_FORCES = ['day', 'gtc', 'ioc', 'fok', 'opg', 'cls', 'gtd'] as const;
export const TimeInForce = sqlEnum(TIME_IN_FORCES);
export type TimeInForce = z.infer<typeof TimeInForce>;

export const ORDER_STATUSES = [
  'draft',
  'pending_risk',
  'risk_rejected',
  'pending_new',
  'new',
  'partially_filled',
  'filled',
  'pending_cancel',
  'cancelled',
  'pending_replace',
  'replaced',
  'rejected',
  'expired',
  'suspended',
] as const;
export const OrderStatus = sqlEnum(ORDER_STATUSES);
export type OrderStatus = z.infer<typeof OrderStatus>;

/** Terminal states, matching the `order_terminal_has_timestamp` CHECK in 0008. */
export const TERMINAL_ORDER_STATUSES = [
  'filled',
  'cancelled',
  'rejected',
  'expired',
  'risk_rejected',
] as const satisfies readonly OrderStatus[];

export function isTerminalOrderStatus(status: OrderStatus): boolean {
  return (TERMINAL_ORDER_STATUSES as readonly OrderStatus[]).includes(status);
}

/** Working states — the set behind the `order_working_idx` partial index. */
export const WORKING_ORDER_STATUSES = [
  'pending_risk',
  'pending_new',
  'new',
  'partially_filled',
  'pending_cancel',
  'pending_replace',
] as const satisfies readonly OrderStatus[];

export function isWorkingOrderStatus(status: OrderStatus): boolean {
  return (WORKING_ORDER_STATUSES as readonly OrderStatus[]).includes(status);
}

export const EXECUTION_ALGOS = [
  'none',
  'twap',
  'vwap',
  'pov',
  'iceberg',
  'sniper',
  'implementation_shortfall',
] as const;
export const ExecutionAlgo = sqlEnum(EXECUTION_ALGOS);
export type ExecutionAlgo = z.infer<typeof ExecutionAlgo>;

export const ORDER_SOURCES = [
  'mobile',
  'web',
  'api',
  'strategy',
  'risk_liquidation',
  'rebalance',
] as const;
export const OrderSource = sqlEnum(ORDER_SOURCES);
export type OrderSource = z.infer<typeof OrderSource>;

export const ORDER_EVENT_TYPES = [
  'created',
  'risk_approved',
  'risk_rejected',
  'submitted',
  'acked',
  'partial_fill',
  'fill',
  'cancel_requested',
  'cancelled',
  'replace_requested',
  'replaced',
  'rejected',
  'expired',
  'suspended',
  'resumed',
  'broker_error',
] as const;
export const OrderEventType = sqlEnum(ORDER_EVENT_TYPES);
export type OrderEventType = z.infer<typeof OrderEventType>;

// ── identity (migration 0002) ────────────────────────────────────────────────
export const USER_STATUSES = [
  'pending_verification',
  'active',
  'suspended',
  'closed',
  'locked',
] as const;
export const UserStatus = sqlEnum(USER_STATUSES);
export type UserStatus = z.infer<typeof UserStatus>;

export const KYC_STATUSES = [
  'not_started',
  'submitted',
  'in_review',
  'approved',
  'rejected',
  'expired',
] as const;
export const KycStatus = sqlEnum(KYC_STATUSES);
export type KycStatus = z.infer<typeof KycStatus>;

export const ACTOR_KINDS = ['user', 'service', 'system', 'admin', 'broker'] as const;
export const ActorKind = sqlEnum(ACTOR_KINDS);
export type ActorKind = z.infer<typeof ActorKind>;

export const CLIENT_PLATFORMS = ['ios', 'android', 'web', 'cli'] as const;
export const ClientPlatform = sqlEnum(CLIENT_PLATFORMS);
export type ClientPlatform = z.infer<typeof ClientPlatform>;

// ── research (migration 0009) ────────────────────────────────────────────────
export const STRATEGY_KINDS = [
  'trend_following',
  'mean_reversion',
  'momentum',
  'statistical_arbitrage',
  'pairs_trading',
  'market_making',
  'volatility',
  'options_income',
  'factor_long_short',
  'risk_parity',
  'event_driven',
  'machine_learning',
  'custom',
] as const;
export const StrategyKind = sqlEnum(STRATEGY_KINDS);
export type StrategyKind = z.infer<typeof StrategyKind>;

export const STRATEGY_STATUSES = [
  'draft',
  'backtesting',
  'validated',
  'paper_trading',
  'live',
  'paused',
  'retired',
] as const;
export const StrategyStatus = sqlEnum(STRATEGY_STATUSES);
export type StrategyStatus = z.infer<typeof StrategyStatus>;

/**
 * A signal says what to do, not which way the book should lean: 'reduce' and
 * 'increase' are relative to the current position, so a strategy can express
 * "trim" without knowing the position size it will be applied against.
 */
export const SIGNAL_ACTIONS = [
  'enter_long',
  'enter_short',
  'exit_long',
  'exit_short',
  'increase',
  'reduce',
  'flat',
  'hold',
  'rebalance',
] as const;
export const SignalAction = sqlEnum(SIGNAL_ACTIONS);
export type SignalAction = z.infer<typeof SignalAction>;

// ── research: backtests and features (migrations 0010, 0011) ─────────────────
export const BACKTEST_STATUSES = [
  'queued',
  'preparing',
  'running',
  'completed',
  'failed',
  'cancelled',
  'expired',
] as const;
export const BacktestStatus = sqlEnum(BACKTEST_STATUSES);
export type BacktestStatus = z.infer<typeof BacktestStatus>;

/**
 * 'paper_forward' and 'live' are sample designations too: a result measured on
 * data the strategy has actually traded through is a stronger claim than an
 * out-of-sample split, and the social layer displays which one it is.
 */
export const SAMPLE_DESIGNATIONS = [
  'in_sample',
  'out_of_sample',
  'walk_forward',
  'paper_forward',
  'live',
] as const;
export const SampleDesignation = sqlEnum(SAMPLE_DESIGNATIONS);
export type SampleDesignation = z.infer<typeof SampleDesignation>;

export const SLIPPAGE_MODELS = [
  'none',
  'fixed_bps',
  'spread_proportional',
  'square_root_impact',
  'book_replay',
] as const;
export const SlippageModel = sqlEnum(SLIPPAGE_MODELS);
export type SlippageModel = z.infer<typeof SlippageModel>;

export const FEATURE_CATEGORIES = [
  'trend',
  'momentum',
  'volatility',
  'mean_reversion',
  'volume',
  'liquidity',
  'microstructure',
  'fundamental',
  'estimate',
  'sentiment',
  'macro',
  'seasonality',
  'cross_sectional',
  'regime',
  'derived',
] as const;
export const FeatureCategory = sqlEnum(FEATURE_CATEGORIES);
export type FeatureCategory = z.infer<typeof FeatureCategory>;

// ── risk (migration 0012) ────────────────────────────────────────────────────
/** `risk.decision`. 'error' is a verdict too: a gate that failed did not approve. */
export const RISK_VERDICTS = ['approved', 'approved_with_warnings', 'rejected', 'error'] as const;
export const RiskVerdict = sqlEnum(RISK_VERDICTS);
export type RiskVerdict = z.infer<typeof RiskVerdict>;

export const RISK_LIMIT_SCOPES = [
  'account',
  'portfolio',
  'deployment',
  'instrument',
  'sector',
  'asset_class',
  'desk',
] as const;
export const RiskLimitScope = sqlEnum(RISK_LIMIT_SCOPES);
export type RiskLimitScope = z.infer<typeof RiskLimitScope>;

export const RISK_LIMIT_KINDS = [
  'max_position_notional',
  'max_position_pct_equity',
  'max_position_pct_adv',
  'max_gross_exposure',
  'max_net_exposure',
  'max_leverage',
  'max_concentration',
  'max_sector_exposure',
  'max_instrument_count',
  'max_daily_loss',
  'max_weekly_loss',
  'max_drawdown',
  'max_order_notional',
  'max_orders_per_minute',
  'max_daily_turnover',
  'min_liquidity_adv',
  'max_var_95',
  'max_portfolio_beta',
  'max_options_delta',
  'max_options_vega',
  'restricted_instrument',
] as const;
export const RiskLimitKind = sqlEnum(RISK_LIMIT_KINDS);
export type RiskLimitKind = z.infer<typeof RiskLimitKind>;

/** hard rejects, soft warns and records, advisory only surfaces in the UI. */
export const RISK_ENFORCEMENTS = ['hard', 'soft', 'advisory'] as const;
export const RiskEnforcement = sqlEnum(RISK_ENFORCEMENTS);
export type RiskEnforcement = z.infer<typeof RiskEnforcement>;

/** Not a SQL enum: the method is a column on `risk.portfolio_snapshot`. */
export const VAR_METHODS = ['historical', 'parametric', 'monte_carlo'] as const;
export const VarMethod = sqlEnum(VAR_METHODS);
export type VarMethod = z.infer<typeof VarMethod>;

// ── notify (migration 0013) ──────────────────────────────────────────────────
export const ALERT_TRIGGER_KINDS = [
  'price_above',
  'price_below',
  'price_crosses',
  'percent_move',
  'percent_move_intraday',
  'gap',
  'volume_spike',
  'unusual_options_activity',
  'indicator_cross',
  'indicator_threshold',
  'earnings_upcoming',
  'corporate_action',
  'order_filled',
  'order_rejected',
  'position_pnl',
  'stop_hit',
  'risk_breach',
  'margin_call',
  'kill_switch',
  'strategy_signal',
  'backtest_complete',
  'broker_sync_stale',
  'reconciliation_break',
  'social_mention',
  'social_follow',
  'social_reply',
] as const;
export const AlertTriggerKind = sqlEnum(ALERT_TRIGGER_KINDS);
export type AlertTriggerKind = z.infer<typeof AlertTriggerKind>;

/**
 * Urgency, not priority: it decides whether a notification may break through a
 * quiet-hours window, which is a user-facing promise rather than a queue hint.
 */
export const NOTIFICATION_URGENCIES = ['critical', 'high', 'normal', 'low'] as const;
export const NotificationUrgency = sqlEnum(NOTIFICATION_URGENCIES);
export type NotificationUrgency = z.infer<typeof NotificationUrgency>;

export const NOTIFICATION_CHANNELS = ['push', 'email', 'sms', 'in_app', 'webhook'] as const;
export const NotificationChannel = sqlEnum(NOTIFICATION_CHANNELS);
export type NotificationChannel = z.infer<typeof NotificationChannel>;

export const NOTIFICATION_STATUSES = [
  'pending',
  'sent',
  'delivered',
  'read',
  'failed',
  'suppressed',
  'expired',
] as const;
export const NotificationStatus = sqlEnum(NOTIFICATION_STATUSES);
export type NotificationStatus = z.infer<typeof NotificationStatus>;

// ── social (planned change: social-trading-network) ──────────────────────────
export const PROFILE_VISIBILITIES = ['public', 'followers', 'private'] as const;
export const ProfileVisibility = sqlEnum(PROFILE_VISIBILITIES);
export type ProfileVisibility = z.infer<typeof ProfileVisibility>;

export const PERFORMANCE_DISCLOSURES = ['none', 'returns_only', 'full'] as const;
export const PerformanceDisclosure = sqlEnum(PERFORMANCE_DISCLOSURES);
export type PerformanceDisclosure = z.infer<typeof PerformanceDisclosure>;

export const POST_KINDS = ['text', 'trade', 'portfolio', 'backtest', 'repost'] as const;
export const PostKind = sqlEnum(POST_KINDS);
export type PostKind = z.infer<typeof PostKind>;

export const POST_VISIBILITIES = ['public', 'followers', 'group'] as const;
export const PostVisibility = sqlEnum(POST_VISIBILITIES);
export type PostVisibility = z.infer<typeof PostVisibility>;

export const MODERATION_STATES = [
  'ok',
  'pending_review',
  'shadow_limited',
  'removed',
  'appealed',
] as const;
export const ModerationState = sqlEnum(MODERATION_STATES);
export type ModerationState = z.infer<typeof ModerationState>;

export const ATTACHMENT_KINDS = ['trade', 'position', 'portfolio', 'backtest', 'media'] as const;
export const AttachmentKind = sqlEnum(ATTACHMENT_KINDS);
export type AttachmentKind = z.infer<typeof AttachmentKind>;

/**
 * The verdict stored on `social.post_attachment` at attach time. `unverified` is
 * the value a verification timeout produces — see the trade-sharing spec: never
 * claim verified on a timeout.
 */
export const VERIFICATION_VERDICTS = ['verified', 'unverified', 'revoked'] as const;
export const VerificationVerdict = sqlEnum(VERIFICATION_VERDICTS);
export type VerificationVerdict = z.infer<typeof VerificationVerdict>;

export const VERIFICATION_METHODS = [
  'helios_routed_order',
  'broker_sync',
  'manual_entry',
  'unavailable',
] as const;
export const VerificationMethod = sqlEnum(VERIFICATION_METHODS);
export type VerificationMethod = z.infer<typeof VerificationMethod>;

export const FOLLOW_STATES = ['pending', 'active'] as const;
export const FollowState = sqlEnum(FOLLOW_STATES);
export type FollowState = z.infer<typeof FollowState>;

export const REACTION_KINDS = ['like', 'insightful', 'disagree', 'bookmark'] as const;
export const ReactionKind = sqlEnum(REACTION_KINDS);
export type ReactionKind = z.infer<typeof ReactionKind>;

export const REPORT_CATEGORIES = [
  'market_manipulation',
  'spam',
  'harassment',
  'impersonation',
  'misinformation',
  'unlicensed_advice',
  'other',
] as const;
export const ReportCategory = sqlEnum(REPORT_CATEGORIES);
export type ReportCategory = z.infer<typeof ReportCategory>;

export const REPORT_STATES = ['open', 'reviewing', 'actioned', 'dismissed'] as const;
export const ReportState = sqlEnum(REPORT_STATES);
export type ReportState = z.infer<typeof ReportState>;

export const REPORT_TARGET_KINDS = ['post', 'profile', 'message'] as const;
export const ReportTargetKind = sqlEnum(REPORT_TARGET_KINDS);
export type ReportTargetKind = z.infer<typeof ReportTargetKind>;

// ── broker connectivity (planned change: broker-connectivity-sync) ───────────
export const PROVIDER_KINDS = ['native', 'aggregator'] as const;
export const ProviderKind = sqlEnum(PROVIDER_KINDS);
export type ProviderKind = z.infer<typeof ProviderKind>;

export const AUTH_KINDS = ['oauth2', 'api_key', 'username_password', 'token_exchange'] as const;
export const AuthKind = sqlEnum(AUTH_KINDS);
export type AuthKind = z.infer<typeof AuthKind>;

export const CONNECTION_STATES = [
  'pending',
  'active',
  'degraded',
  'reauthorisation_required',
  'disconnected',
  'revoked',
] as const;
export const ConnectionState = sqlEnum(CONNECTION_STATES);
export type ConnectionState = z.infer<typeof ConnectionState>;

export const SYNC_RESOURCES = ['balances', 'positions', 'transactions', 'orders', 'lots'] as const;
export const SyncResource = sqlEnum(SYNC_RESOURCES);
export type SyncResource = z.infer<typeof SyncResource>;

export const SYNC_OUTCOMES = [
  'success',
  'partial',
  'rate_limited',
  'auth_failed',
  'contract_violation',
  'provider_error',
  'cancelled',
] as const;
export const SyncOutcome = sqlEnum(SYNC_OUTCOMES);
export type SyncOutcome = z.infer<typeof SyncOutcome>;

/** `sourced | reconstructed | estimated` — the holdings-sync spec's lot quality. */
export const BASIS_QUALITIES = ['sourced', 'reconstructed', 'estimated'] as const;
export const BasisQuality = sqlEnum(BASIS_QUALITIES);
export type BasisQuality = z.infer<typeof BasisQuality>;

export const TRANSACTION_KINDS = [
  'trade',
  'dividend',
  'interest',
  'fee',
  'tax',
  'deposit',
  'withdrawal',
  'transfer',
  'corporate_action',
  'assignment',
  'exercise',
  'expiration',
  'unknown',
] as const;
export const TransactionKind = sqlEnum(TRANSACTION_KINDS);
export type TransactionKind = z.infer<typeof TransactionKind>;

export const RECONCILIATION_BREAK_TYPES = [
  'quantity',
  'cash',
  'cost_basis',
  'missing_in_broker',
  'missing_in_helios',
  'corporate_action_suspected',
] as const;
export const ReconciliationBreakType = sqlEnum(RECONCILIATION_BREAK_TYPES);
export type ReconciliationBreakType = z.infer<typeof ReconciliationBreakType>;

export const IMPORT_BATCH_STATES = [
  'uploaded',
  'mapping',
  'previewed',
  'committing',
  'committed',
  'failed',
  'abandoned',
] as const;
export const ImportBatchState = sqlEnum(IMPORT_BATCH_STATES);
export type ImportBatchState = z.infer<typeof ImportBatchState>;

export const IMPORT_ROW_OUTCOMES = ['creatable', 'duplicate', 'rejected'] as const;
export const ImportRowOutcome = sqlEnum(IMPORT_ROW_OUTCOMES);
export type ImportRowOutcome = z.infer<typeof ImportRowOutcome>;
