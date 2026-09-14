/**
 * Reference and market-data contracts — `reference.*` and `market.*`
 * (db/migrations/0003, 0004).
 *
 * Field names are the SQL column names. The gateway could camel-case them on the
 * way out, but every one of these shapes is also produced by the Go ingestor and
 * the Python quant engine, and a single naming convention across all three is
 * worth more than idiomatic JS casing in one of them.
 */
import { z } from 'zod';
import {
  AssetClass,
  BarInterval,
  DataQuality,
  ExerciseStyle,
  InstrumentStatus,
  OptionType,
  SettlementType,
  Side,
  VenueKind,
} from './enums.js';
import {
  Bps,
  CurrencyCode,
  InstrumentId,
  IsoDate,
  Money,
  Price,
  Quantity,
  Ratio,
  SignedPrice,
  Ticker,
  Timestamp,
  VenueId,
} from './primitives.js';

/** A price band from `reference.venue.tick_size_regime`: ticks widen with price. */
export const TickSizeBand = z.object({
  max_price: Price,
  tick: Price,
});
export type TickSizeBand = z.infer<typeof TickSizeBand>;

export const Venue = z.object({
  id: VenueId,
  /** ISO 10383 MIC; null for crypto venues, which have none. */
  mic: z.string().length(4).nullable(),
  code: z.string().min(1).max(24),
  name: z.string().min(1).max(120),
  kind: VenueKind,
  country_code: z.string().length(2).nullable(),
  timezone: z.string().min(1),
  currency: CurrencyCode,
  tick_size_regime: z.array(TickSizeBand).default([]),
  lot_size: z.number().int().positive(),
  supports_odd_lots: z.boolean(),
  maker_fee_bps: Bps,
  taker_fee_bps: Bps,
  settlement_days: z.number().int().min(0).max(5),
  has_pre_market: z.boolean(),
  has_post_market: z.boolean(),
  is_24h: z.boolean(),
  is_active: z.boolean(),
});
export type Venue = z.infer<typeof Venue>;

export const Instrument = z.object({
  id: InstrumentId,
  symbol: Ticker,
  venue_id: VenueId,
  asset_class: AssetClass,
  name: z.string().min(1).max(200),
  currency: CurrencyCode,
  status: InstrumentStatus,
  // Cross-vendor identifiers. figi is the preferred join key for equities.
  figi: z.string().length(12).nullable().default(null),
  isin: z.string().length(12).nullable().default(null),
  cusip: z.string().length(9).nullable().default(null),
  sedol: z.string().length(7).nullable().default(null),
  sector_id: z.number().int().positive().nullable().default(null),
  country_code: z.string().length(2).nullable().default(null),
  // Microstructure. `multiplier` is 100 for equity options and drives every
  // notional calculation, so it is required rather than defaulted by the client.
  tick_size: Price.nullable().default(null),
  lot_size: Quantity,
  min_order_qty: Quantity,
  max_order_qty: Quantity.nullable().default(null),
  multiplier: Ratio,
  is_shortable: z.boolean(),
  is_marginable: z.boolean(),
  is_fractionable: z.boolean(),
  maintenance_margin_rate: Ratio.nullable().default(null),
  short_borrow_rate_bps: Bps.nullable().default(null),
  adv_30d: Quantity.nullable().default(null),
  median_spread_bps: Bps.nullable().default(null),
  market_cap: Money.nullable().default(null),
  listed_on: IsoDate.nullable().default(null),
  delisted_on: IsoDate.nullable().default(null),
  data_start_date: IsoDate.nullable().default(null),
});
export type Instrument = z.infer<typeof Instrument>;

/**
 * A tradeable instrument as the mobile search bar needs it: enough to render a
 * row and to build an order ticket, nothing more. Separate from `Instrument`
 * because search returns hundreds of these and the payload size is felt.
 */
export const InstrumentSummary = Instrument.pick({
  id: true,
  symbol: true,
  name: true,
  asset_class: true,
  currency: true,
  status: true,
  venue_id: true,
  is_fractionable: true,
  multiplier: true,
});
export type InstrumentSummary = z.infer<typeof InstrumentSummary>;

export const OptionContract = z.object({
  instrument_id: InstrumentId,
  underlying_id: InstrumentId,
  option_type: OptionType,
  strike: Price,
  expiration_date: IsoDate,
  exercise_style: ExerciseStyle,
  settlement: SettlementType,
  contract_size: Quantity,
  occ_symbol: z.string().max(24).nullable().default(null),
  is_weekly: z.boolean().default(false),
  is_mini: z.boolean().default(false),
  open_interest: z.number().int().nonnegative().nullable().default(null),
  open_interest_date: IsoDate.nullable().default(null),
});
export type OptionContract = z.infer<typeof OptionContract>;

/**
 * OHLCV bar. `ts` is the bar OPEN time — the single most common off-by-one-bar
 * bug in backtesting is mixing open-stamped and close-stamped bars, so the
 * convention is stated here and asserted by the ingestor's contract tests.
 */
export const Bar = z
  .object({
    ts: Timestamp,
    instrument_id: InstrumentId,
    interval: BarInterval,
    open: Price,
    high: Price,
    low: Price,
    close: Price,
    volume: Quantity,
    trade_count: z.number().int().nonnegative().nullable().default(null),
    vwap: Price.nullable().default(null),
    session: z.enum(['pre', 'regular', 'post']).default('regular'),
    quality: DataQuality.default('vendor'),
    source: z.string().max(24).default('aggregated'),
  })
  .superRefine((bar, ctx) => {
    // Mirrors the bar_*_ohlc_coherent CHECK constraints. A vendor sending an
    // incoherent bar is common enough that catching it at the edge is worth the
    // four comparisons; the alternative is a backtest with an impossible fill.
    const h = Number(bar.high);
    const l = Number(bar.low);
    const o = Number(bar.open);
    const c = Number(bar.close);
    if (!(h >= l && h >= o && h >= c && l <= o && l <= c)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'incoherent OHLC: require high >= max(open, close) and low <= min(open, close)',
        path: ['high'],
      });
    }
  });
export type Bar = z.infer<typeof Bar>;

/** Daily bars carry the official prints and pre-computed returns from 0004. */
export const DailyBar = z.object({
  ts: Timestamp,
  instrument_id: InstrumentId,
  open: Price,
  high: Price,
  low: Price,
  close: Price,
  volume: Quantity,
  vwap: Price.nullable().default(null),
  official_close: Price.nullable().default(null),
  settlement_price: Price.nullable().default(null),
  open_interest: z.number().int().nonnegative().nullable().default(null),
  prev_close: Price.nullable().default(null),
  return_simple: Ratio.nullable().default(null),
  return_log: Ratio.nullable().default(null),
  gap_pct: Ratio.nullable().default(null),
  true_range: SignedPrice.nullable().default(null),
  dollar_volume: Money.nullable().default(null),
  quality: DataQuality.default('vendor'),
});
export type DailyBar = z.infer<typeof DailyBar>;

/**
 * Top of book. `spread` and `mid` are generated columns in SQL and are passed
 * through rather than recomputed: the client recomputing them from rounded
 * inputs is how a UI ends up disagreeing with the risk engine by a cent.
 */
export const Quote = z.object({
  ts: Timestamp,
  instrument_id: InstrumentId,
  bid_price: Price.nullable(),
  bid_size: Quantity.nullable(),
  ask_price: Price.nullable(),
  ask_size: Quantity.nullable(),
  bid_venue_id: VenueId.nullable().default(null),
  ask_venue_id: VenueId.nullable().default(null),
  spread: SignedPrice.nullable().default(null),
  mid: Price.nullable().default(null),
  exchange_ts: Timestamp.nullable().default(null),
});
export type Quote = z.infer<typeof Quote>;

export const Trade = z.object({
  ts: Timestamp,
  instrument_id: InstrumentId,
  price: Price,
  size: Quantity,
  trade_id: z.string().max(48).nullable().default(null),
  venue_id: VenueId,
  /** Null when the venue does not tag the aggressing side. */
  aggressor: Side.nullable().default(null),
  conditions: z.array(z.string().max(8)).default([]),
  exchange_ts: Timestamp.nullable().default(null),
  quality: DataQuality.default('vendor'),
});
export type Trade = z.infer<typeof Trade>;

/** One level of a depth snapshot. */
export const BookLevel = z.object({
  price: Price,
  size: Quantity,
  order_count: z.number().int().nonnegative().nullable().default(null),
});
export type BookLevel = z.infer<typeof BookLevel>;

export const DepthSnapshot = z.object({
  ts: Timestamp,
  instrument_id: InstrumentId,
  bids: z.array(BookLevel),
  asks: z.array(BookLevel),
  sequence: z.number().int().nonnegative().nullable().default(null),
});
export type DepthSnapshot = z.infer<typeof DepthSnapshot>;

/**
 * Annualisation factors per interval, kept identical to
 * `platform.periods_per_year()` in migration 0001. Two implementations of this
 * number that disagree produce two different Sharpe ratios for the same
 * strategy, which is a support ticket nobody can resolve.
 */
export const PERIODS_PER_YEAR: Record<z.infer<typeof BarInterval>, number> = {
  '1s': 252 * 6.5 * 3600,
  '5s': 252 * 6.5 * 720,
  '15s': 252 * 6.5 * 240,
  '1m': 252 * 390,
  '5m': 252 * 78,
  '15m': 252 * 26,
  '30m': 252 * 13,
  '1h': 252 * 6.5,
  '4h': 252 * 1.625,
  '1d': 252,
  '1w': 52,
  '1mo': 12,
};
