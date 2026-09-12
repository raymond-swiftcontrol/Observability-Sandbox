-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0005 · Compression, retention and reorder policies                        ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Storage economics drive these numbers. Raw ticks at ~2M rows/day/venue are
-- ~140 GB/year uncompressed; segmented columnar compression takes that to
-- ~9 GB, and after 7 days Postgres is no longer the query path for ticks —
-- ClickHouse is (see db/analytics). Postgres keeps a 90-day tail for
-- reconciliation and audit, then drops chunks.
--
-- segmentby: the column queries filter on (instrument_id) — rows sharing a
--            segment value compress together and can be filtered without
--            decompressing.
-- orderby:   the column queries range-scan (ts) — determines intra-batch
--            ordering and therefore the delta-encoding ratio.

-- ── Trades ───────────────────────────────────────────────────────────────────
ALTER TABLE market.trade SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'instrument_id, venue_id',
  timescaledb.compress_orderby   = 'ts DESC, trade_id',
  timescaledb.compress_chunk_time_interval = '6 hours'
);
SELECT add_compression_policy('market.trade', INTERVAL '2 hours');
SELECT add_retention_policy('market.trade', INTERVAL '90 days');

-- ── Quotes ───────────────────────────────────────────────────────────────────
-- Quotes are the highest-volume table and the least useful after the fact;
-- 14 days covers any post-trade execution-quality review.
ALTER TABLE market.quote SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'instrument_id',
  timescaledb.compress_orderby   = 'ts DESC'
);
SELECT add_compression_policy('market.quote', INTERVAL '1 hour');
SELECT add_retention_policy('market.quote', INTERVAL '14 days');

-- ── Bars ─────────────────────────────────────────────────────────────────────
-- Intraday bars are the research workhorse; keep 5 years. They compress ~12x.
ALTER TABLE market.bar_1m SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'instrument_id',
  timescaledb.compress_orderby   = 'ts DESC'
);
SELECT add_compression_policy('market.bar_1m', INTERVAL '7 days');
SELECT add_retention_policy('market.bar_1m', INTERVAL '5 years');

-- Daily bars are never dropped: they are the longest-horizon research asset and
-- the entire history is only a few GB compressed.
ALTER TABLE market.bar_1d SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'instrument_id',
  timescaledb.compress_orderby   = 'ts DESC'
);
SELECT add_compression_policy('market.bar_1d', INTERVAL '90 days');

-- ── Books and options ────────────────────────────────────────────────────────
ALTER TABLE market.book_snapshot SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'instrument_id',
  timescaledb.compress_orderby   = 'ts DESC'
);
SELECT add_compression_policy('market.book_snapshot', INTERVAL '1 hour');
SELECT add_retention_policy('market.book_snapshot', INTERVAL '7 days');

ALTER TABLE market.option_quote SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'underlying_id, instrument_id',
  timescaledb.compress_orderby   = 'ts DESC'
);
SELECT add_compression_policy('market.option_quote', INTERVAL '3 days');
SELECT add_retention_policy('market.option_quote', INTERVAL '2 years');

-- ── Telemetry ────────────────────────────────────────────────────────────────
ALTER TABLE market.feed_health SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'vendor, feed'
);
SELECT add_compression_policy('market.feed_health', INTERVAL '7 days');
SELECT add_retention_policy('market.feed_health', INTERVAL '180 days');

-- ── Continuous aggregate retention ───────────────────────────────────────────
-- The aggregates outlive the 1m source for coarse resolutions, which is the
-- point: a 10-year hourly history costs almost nothing.
SELECT add_retention_policy('market.bar_5m',  INTERVAL '2 years');
SELECT add_retention_policy('market.bar_15m', INTERVAL '5 years');
-- bar_1h and bar_1w are kept indefinitely.

-- ── Reorder policies ─────────────────────────────────────────────────────────
-- Uncompressed chunks are written in arrival order, which is time-major. Most
-- reads are instrument-major, so physically reorder recent chunks by the index
-- that matters. Applies only to chunks not yet compressed.
SELECT add_reorder_policy('market.bar_1m', 'bar_1m_pk_idx', if_not_exists => true);
SELECT add_reorder_policy('market.bar_1d', 'bar_1d_pk_idx', if_not_exists => true);

-- ── Visible inventory of what the policies are doing ─────────────────────────
-- Pointed at by the Grafana "storage" dashboard and the weekly capacity review.
CREATE OR REPLACE VIEW market.storage_report AS
SELECT h.hypertable_schema || '.' || h.hypertable_name         AS hypertable,
       h.num_chunks,
       pg_size_pretty(hs.table_bytes)                          AS uncompressed,
       pg_size_pretty(hs.total_bytes)                           AS total,
       pg_size_pretty(hs.index_bytes)                           AS indexes,
       cs.number_compressed_chunks,
       pg_size_pretty(cs.before_compression_total_bytes)        AS before_compression,
       pg_size_pretty(cs.after_compression_total_bytes)         AS after_compression,
       round(
         platform.safe_div(
           cs.before_compression_total_bytes::numeric,
           nullif(cs.after_compression_total_bytes, 0)::numeric
         ), 1)                                                  AS compression_ratio
  FROM timescaledb_information.hypertables h
  LEFT JOIN LATERAL hypertable_detailed_size(
         format('%I.%I', h.hypertable_schema, h.hypertable_name)::regclass) hs ON true
  LEFT JOIN LATERAL hypertable_compression_stats(
         format('%I.%I', h.hypertable_schema, h.hypertable_name)::regclass) cs ON true
 WHERE h.hypertable_schema IN ('market', 'research', 'risk', 'book');

COMMENT ON VIEW market.storage_report IS
  'Per-hypertable size and compression effectiveness. If a ratio drops below ~5x, check that compress_segmentby still matches the dominant query predicate.';
