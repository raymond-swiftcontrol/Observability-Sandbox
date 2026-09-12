-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0004 · Market data: ticks, quotes, bars, order books (Timescale)          ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Design notes
--  • Everything here is append-only and partitioned by time. Chunk intervals
--    are tuned so that one chunk ≈ 1–2 GB at expected volume: the guidance is
--    that recent chunks plus their indexes should fit in memory.
--  • Bars are stored RAW (as printed by the venue). Adjusted prices are derived
--    on read via reference.adjustment_factor, so a late corporate action never
--    requires rewriting history.
--  • 1m bars are the only ingested intraday resolution; 5m/15m/30m/1h/4h are
--    continuous aggregates. Storing each resolution independently is how bar
--    sets silently disagree with each other.

-- ── Trades (tick level) ──────────────────────────────────────────────────────
CREATE TABLE market.trade (
  ts            timestamptz      NOT NULL,
  instrument_id uuid             NOT NULL,
  price         reference.price  NOT NULL,
  size          reference.quantity NOT NULL,
  -- Venue-assigned id; used to dedupe on vendor replay. Not globally unique
  -- across venues, hence the composite uniqueness below.
  trade_id      varchar(48),
  venue_id      smallint         NOT NULL,
  aggressor     reference.side,             -- null when the venue does not tag it
  conditions    varchar(8)[]     NOT NULL DEFAULT '{}',
  -- Exchange timestamp vs. our receipt time: the gap is the feed latency we
  -- alert on, and it matters for any strategy claiming intraday edge.
  exchange_ts   timestamptz,
  ingested_at   timestamptz      NOT NULL DEFAULT now(),
  quality       reference.data_quality NOT NULL DEFAULT 'vendor',
  CONSTRAINT trade_price_positive CHECK (price > 0),
  CONSTRAINT trade_size_positive  CHECK (size > 0)
);

SELECT create_hypertable(
  'market.trade', 'ts',
  partitioning_column => 'instrument_id',
  number_partitions   => 16,
  chunk_time_interval => INTERVAL '1 hour',
  create_default_indexes => false
);

-- Space partitioning by instrument keeps per-symbol scans inside one chunk
-- dimension, which is the dominant query shape (one symbol, one day).
CREATE UNIQUE INDEX trade_dedupe_idx
  ON market.trade (instrument_id, ts, trade_id, venue_id)
  WHERE trade_id IS NOT NULL;
CREATE INDEX trade_instrument_ts_idx ON market.trade (instrument_id, ts DESC);
CREATE INDEX trade_ts_idx            ON market.trade (ts DESC);
CREATE INDEX trade_large_print_idx   ON market.trade (instrument_id, ts DESC)
  WHERE size >= 10000;   -- block-trade / sweep detection

-- ── Top of book ──────────────────────────────────────────────────────────────
CREATE TABLE market.quote (
  ts            timestamptz NOT NULL,
  instrument_id uuid        NOT NULL,
  bid_price     reference.price,
  bid_size      reference.quantity,
  ask_price     reference.price,
  ask_size      reference.quantity,
  bid_venue_id  smallint,
  ask_venue_id  smallint,
  -- Denormalised because every microstructure feature recomputes them and the
  -- arithmetic is not free at 2M rows/minute.
  spread        reference.signed_px GENERATED ALWAYS AS (ask_price - bid_price) STORED,
  mid           reference.price     GENERATED ALWAYS AS ((ask_price + bid_price) / 2) STORED,
  exchange_ts   timestamptz,
  ingested_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT quote_not_crossed CHECK (
    bid_price IS NULL OR ask_price IS NULL OR ask_price >= bid_price
  )
);

SELECT create_hypertable(
  'market.quote', 'ts',
  partitioning_column => 'instrument_id',
  number_partitions   => 16,
  chunk_time_interval => INTERVAL '30 minutes',
  create_default_indexes => false
);

CREATE INDEX quote_instrument_ts_idx ON market.quote (instrument_id, ts DESC);
CREATE INDEX quote_wide_spread_idx   ON market.quote (instrument_id, ts DESC)
  WHERE spread IS NOT NULL;

COMMENT ON CONSTRAINT quote_not_crossed ON market.quote IS
  'Crossed books are real but almost always a feed defect; the ingestor routes violations to the DLQ rather than dropping them.';

-- ── Bars (1m is ingested; coarser resolutions are continuous aggregates) ─────
CREATE TABLE market.bar_1m (
  ts            timestamptz NOT NULL,     -- bar OPEN time, venue timezone-aware
  instrument_id uuid        NOT NULL,
  open          reference.price NOT NULL,
  high          reference.price NOT NULL,
  low           reference.price NOT NULL,
  close         reference.price NOT NULL,
  volume        reference.quantity NOT NULL DEFAULT 0,
  trade_count   integer,
  vwap          reference.price,
  -- Extended-hours bars are kept but flagged: most strategies must exclude them.
  session       varchar(12) NOT NULL DEFAULT 'regular',  -- pre | regular | post
  quality       reference.data_quality NOT NULL DEFAULT 'vendor',
  source        varchar(24) NOT NULL DEFAULT 'aggregated',
  ingested_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bar_1m_ohlc_coherent CHECK (
    high >= low AND high >= open AND high >= close AND low <= open AND low <= close
  ),
  CONSTRAINT bar_1m_volume_nonneg CHECK (volume >= 0)
);

SELECT create_hypertable(
  'market.bar_1m', 'ts',
  partitioning_column => 'instrument_id',
  number_partitions   => 8,
  chunk_time_interval => INTERVAL '1 day',
  create_default_indexes => false
);

CREATE UNIQUE INDEX bar_1m_pk_idx ON market.bar_1m (instrument_id, ts);
CREATE INDEX bar_1m_ts_idx ON market.bar_1m (ts DESC);

-- Daily bars arrive from a different vendor path (official close, adjusted
-- volume, settlement) so they are a table rather than an aggregate of 1m.
CREATE TABLE market.bar_1d (
  ts              timestamptz NOT NULL,
  instrument_id   uuid        NOT NULL,
  open            reference.price NOT NULL,
  high            reference.price NOT NULL,
  low             reference.price NOT NULL,
  close           reference.price NOT NULL,
  volume          reference.quantity NOT NULL DEFAULT 0,
  trade_count     integer,
  vwap            reference.price,
  -- Official prints that differ from the intraday tape.
  official_close  reference.price,
  settlement_price reference.price,
  open_interest   bigint,
  -- Pre-computed returns: every research query wants them and computing with
  -- window functions over 40M rows on each call is wasteful.
  prev_close      reference.price,
  return_simple   reference.ratio,
  return_log      reference.ratio,
  gap_pct         reference.ratio,
  true_range      reference.signed_px,
  dollar_volume   reference.money,
  quality         reference.data_quality NOT NULL DEFAULT 'vendor',
  source          varchar(24) NOT NULL,
  ingested_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bar_1d_ohlc_coherent CHECK (
    high >= low AND high >= open AND high >= close AND low <= open AND low <= close
  )
);

SELECT create_hypertable(
  'market.bar_1d', 'ts',
  chunk_time_interval => INTERVAL '30 days',
  create_default_indexes => false
);

CREATE UNIQUE INDEX bar_1d_pk_idx ON market.bar_1d (instrument_id, ts DESC);
CREATE INDEX bar_1d_ts_idx ON market.bar_1d (ts DESC);
CREATE INDEX bar_1d_dollar_volume_idx ON market.bar_1d (ts DESC, dollar_volume DESC);

-- Derived columns are maintained by trigger rather than GENERATED because they
-- depend on the previous row, which generated columns cannot see.
CREATE OR REPLACE FUNCTION market.bar_1d_derive() RETURNS trigger
  LANGUAGE plpgsql AS $$
DECLARE prev reference.price;
BEGIN
  IF NEW.prev_close IS NULL THEN
    SELECT b.close INTO prev
      FROM market.bar_1d b
     WHERE b.instrument_id = NEW.instrument_id AND b.ts < NEW.ts
     ORDER BY b.ts DESC LIMIT 1;
    NEW.prev_close := prev;
  END IF;

  IF NEW.prev_close IS NOT NULL AND NEW.prev_close > 0 THEN
    NEW.return_simple := (NEW.close - NEW.prev_close) / NEW.prev_close;
    NEW.return_log    := ln(NEW.close / NEW.prev_close);
    NEW.gap_pct       := (NEW.open - NEW.prev_close) / NEW.prev_close;
    NEW.true_range    := greatest(
      NEW.high - NEW.low,
      abs(NEW.high - NEW.prev_close),
      abs(NEW.low  - NEW.prev_close)
    );
  ELSE
    NEW.true_range := NEW.high - NEW.low;
  END IF;

  NEW.dollar_volume := coalesce(NEW.vwap, NEW.close) * NEW.volume;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_bar_1d_derive
  BEFORE INSERT OR UPDATE ON market.bar_1d
  FOR EACH ROW EXECUTE FUNCTION market.bar_1d_derive();

-- ── Continuous aggregates: intraday roll-ups from 1m ────────────────────────
-- candlestick_agg from timescaledb_toolkit would be tidier, but first/last
-- keeps this portable to plain Timescale installs.
CREATE MATERIALIZED VIEW market.bar_5m
WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '5 minutes', ts) AS ts,
       instrument_id,
       first(open, ts)  AS open,
       max(high)        AS high,
       min(low)         AS low,
       last(close, ts)  AS close,
       sum(volume)      AS volume,
       sum(trade_count) AS trade_count,
       CASE WHEN sum(volume) > 0
            THEN sum(coalesce(vwap, close) * volume) / sum(volume) END AS vwap
  FROM market.bar_1m
 WHERE session = 'regular'
 GROUP BY 1, 2
WITH NO DATA;

CREATE MATERIALIZED VIEW market.bar_15m
WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '15 minutes', ts) AS ts,
       instrument_id,
       first(open, ts) AS open, max(high) AS high, min(low) AS low,
       last(close, ts) AS close, sum(volume) AS volume, sum(trade_count) AS trade_count,
       CASE WHEN sum(volume) > 0
            THEN sum(coalesce(vwap, close) * volume) / sum(volume) END AS vwap
  FROM market.bar_1m
 WHERE session = 'regular'
 GROUP BY 1, 2
WITH NO DATA;

CREATE MATERIALIZED VIEW market.bar_1h
WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '1 hour', ts) AS ts,
       instrument_id,
       first(open, ts) AS open, max(high) AS high, min(low) AS low,
       last(close, ts) AS close, sum(volume) AS volume, sum(trade_count) AS trade_count,
       CASE WHEN sum(volume) > 0
            THEN sum(coalesce(vwap, close) * volume) / sum(volume) END AS vwap
  FROM market.bar_1m
 WHERE session = 'regular'
 GROUP BY 1, 2
WITH NO DATA;

-- Weekly/monthly roll up from daily bars.
CREATE MATERIALIZED VIEW market.bar_1w
WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '1 week', ts) AS ts,
       instrument_id,
       first(open, ts) AS open, max(high) AS high, min(low) AS low,
       last(close, ts) AS close, sum(volume) AS volume,
       sum(dollar_volume) AS dollar_volume
  FROM market.bar_1d
 GROUP BY 1, 2
WITH NO DATA;

-- Refresh policies: start_offset bounds how far back a late-arriving bar can
-- still be folded in; end_offset keeps the aggregate off the hot write edge.
SELECT add_continuous_aggregate_policy('market.bar_5m',
  start_offset => INTERVAL '3 hours', end_offset => INTERVAL '2 minutes',
  schedule_interval => INTERVAL '1 minute');
SELECT add_continuous_aggregate_policy('market.bar_15m',
  start_offset => INTERVAL '6 hours', end_offset => INTERVAL '5 minutes',
  schedule_interval => INTERVAL '5 minutes');
SELECT add_continuous_aggregate_policy('market.bar_1h',
  start_offset => INTERVAL '2 days', end_offset => INTERVAL '15 minutes',
  schedule_interval => INTERVAL '15 minutes');
SELECT add_continuous_aggregate_policy('market.bar_1w',
  start_offset => INTERVAL '60 days', end_offset => INTERVAL '1 day',
  schedule_interval => INTERVAL '1 hour');

CREATE INDEX bar_5m_instrument_ts_idx  ON market.bar_5m  (instrument_id, ts DESC);
CREATE INDEX bar_15m_instrument_ts_idx ON market.bar_15m (instrument_id, ts DESC);
CREATE INDEX bar_1h_instrument_ts_idx  ON market.bar_1h  (instrument_id, ts DESC);
CREATE INDEX bar_1w_instrument_ts_idx  ON market.bar_1w  (instrument_id, ts DESC);

-- ── Order book snapshots (L2) ───────────────────────────────────────────────
-- Full depth as a jsonb array is slower than separate level rows to query but
-- 10x cheaper to write and compress, and backtests read whole snapshots anyway.
CREATE TABLE market.book_snapshot (
  ts            timestamptz NOT NULL,
  instrument_id uuid        NOT NULL,
  sequence      bigint,
  bids          jsonb       NOT NULL,    -- [[price, size], …] descending
  asks          jsonb       NOT NULL,    -- [[price, size], …] ascending
  depth_levels  smallint    NOT NULL,
  -- Imbalance at the touch: the single most reused microstructure feature.
  imbalance_l1  reference.ratio,
  imbalance_l5  reference.ratio,
  ingested_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT book_sides_are_arrays
    CHECK (jsonb_typeof(bids) = 'array' AND jsonb_typeof(asks) = 'array')
);

SELECT create_hypertable(
  'market.book_snapshot', 'ts',
  partitioning_column => 'instrument_id',
  number_partitions   => 8,
  chunk_time_interval => INTERVAL '15 minutes',
  create_default_indexes => false
);

CREATE INDEX book_snapshot_instrument_ts_idx
  ON market.book_snapshot (instrument_id, ts DESC);

-- ── Options greeks / IV surface snapshots ───────────────────────────────────
CREATE TABLE market.option_quote (
  ts              timestamptz NOT NULL,
  instrument_id   uuid        NOT NULL,   -- the option contract
  underlying_id   uuid        NOT NULL,
  bid             reference.price,
  ask             reference.price,
  last            reference.price,
  volume          reference.quantity NOT NULL DEFAULT 0,
  open_interest   bigint,
  underlying_price reference.price,
  -- Vendor IV when supplied, ours otherwise; vega-weighted mid is the default.
  implied_vol     reference.ratio,
  iv_source       varchar(16) NOT NULL DEFAULT 'computed',
  delta           reference.ratio,
  gamma           reference.ratio,
  theta           reference.ratio,
  vega            reference.ratio,
  rho             reference.ratio,
  -- Second-order greeks matter for vol strategies and are cheap to store.
  vanna           reference.ratio,
  charm           reference.ratio,
  risk_free_rate  reference.ratio,
  dividend_yield  reference.ratio,
  ingested_at     timestamptz NOT NULL DEFAULT now()
);

SELECT create_hypertable(
  'market.option_quote', 'ts',
  partitioning_column => 'underlying_id',
  number_partitions   => 8,
  chunk_time_interval => INTERVAL '1 day',
  create_default_indexes => false
);

CREATE INDEX option_quote_contract_ts_idx ON market.option_quote (instrument_id, ts DESC);
CREATE INDEX option_quote_underlying_ts_idx ON market.option_quote (underlying_id, ts DESC);

-- ── Feed health (the observability part of the sandbox) ─────────────────────
CREATE TABLE market.feed_health (
  ts               timestamptz NOT NULL,
  vendor           varchar(24) NOT NULL,
  feed             varchar(32) NOT NULL,   -- trades | quotes | bars | book
  messages         bigint      NOT NULL DEFAULT 0,
  bytes            bigint      NOT NULL DEFAULT 0,
  gaps_detected    integer     NOT NULL DEFAULT 0,
  sequence_resets  integer     NOT NULL DEFAULT 0,
  p50_latency_ms   integer,
  p99_latency_ms   integer,
  max_latency_ms   integer,
  reconnects       integer     NOT NULL DEFAULT 0,
  last_error       text,
  PRIMARY KEY (ts, vendor, feed)
);

SELECT create_hypertable('market.feed_health', 'ts',
  chunk_time_interval => INTERVAL '1 day');

-- Explicit, auditable record of every gap we know about, so research can
-- exclude affected windows instead of silently training on holes.
CREATE TABLE market.data_gap (
  id            bigserial PRIMARY KEY,
  instrument_id uuid REFERENCES reference.instrument(id) ON DELETE CASCADE,
  feed          varchar(32) NOT NULL,
  gap_start     timestamptz NOT NULL,
  gap_end       timestamptz NOT NULL,
  expected_rows integer,
  actual_rows   integer,
  detected_at   timestamptz NOT NULL DEFAULT now(),
  backfilled_at timestamptz,
  backfill_source varchar(24),
  CONSTRAINT data_gap_ordered CHECK (gap_end > gap_start)
);

CREATE INDEX data_gap_open_idx ON market.data_gap (instrument_id, gap_start DESC)
  WHERE backfilled_at IS NULL;
