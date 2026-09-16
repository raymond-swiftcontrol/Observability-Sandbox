package sink

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/clock"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
)

// Pool is the subset of *pgxpool.Pool this package needs, narrowed so tests
// run without a real Postgres.
type Pool interface {
	CopyFrom(ctx context.Context, tableName pgx.Identifier, columnNames []string, rowSrc pgx.CopyFromSource) (int64, error)
	Ping(ctx context.Context) error
}

// BatchConfig tunes one TableWriter. Field names mirror
// config.DatabaseConfig so callers pass it straight through.
type BatchConfig struct {
	// BatchRows triggers a flush once this many rows are buffered.
	BatchRows int
	// BatchInterval triggers a flush this often even if BatchRows was never
	// reached, so a quiet symbol set still lands within one interval.
	BatchInterval time.Duration
	// BufferRows bounds the in-memory backlog tolerated while the database is
	// unavailable. Once the backlog is at this bound, further rows are shed
	// (dropped, counted, logged) rather than buffered — see the package doc.
	BufferRows int
}

func (c *BatchConfig) withDefaults() {
	if c.BatchRows <= 0 {
		c.BatchRows = 5000
	}
	if c.BatchInterval <= 0 {
		c.BatchInterval = 2 * time.Second
	}
	if c.BufferRows <= 0 {
		c.BufferRows = 200000
	}
}

// TableWriter batches rows of type T into a single Postgres table via
// CopyFrom, flushing on whichever of size or time comes first.
//
// Failure handling — the important part: a CopyFrom error leaves the batch
// exactly where it was (prepended back onto whatever arrived meanwhile) so
// the same rows are retried on the next flush tick rather than lost. Add
// keeps accepting rows up to BufferRows while that backlog grows during an
// outage; once the backlog is at the bound, Add sheds — drops the incoming
// row, increments DBShedRows, and logs at error level — rather than let a
// stalled database turn into unbounded ingestor memory growth. This is a
// documented, intentional data-loss path, not a bug: the alternative is an
// OOM that loses everything instead of the tail end of an outage.
//
// One approximation is worth calling out: because a failed batch is merged
// back with whatever Add appended while the CopyFrom attempt was in flight,
// the buffer can transiently exceed BufferRows by up to one in-flight
// batch's worth of rows before the next Add call starts shedding again. The
// bound is therefore soft, not hard; making it exact would require holding
// the write lock for the full duration of every CopyFrom call, which would
// stall Add — and therefore the whole ingestion hot path — behind Postgres
// latency.
type TableWriter[T any] struct {
	table   string
	pool    Pool
	toRow   func(T) []any
	columns []string
	cfg     BatchConfig
	clk     clock.Clock
	metrics Metrics
	logger  *slog.Logger

	flushNow chan struct{}

	mu  sync.Mutex
	buf []T
}

// NewTableWriter builds a TableWriter. table is schema-qualified
// (e.g. "market.trade"); columns must list exactly the columns toRow
// produces, in order, and must exclude any GENERATED or DEFAULT-only column
// (ingested_at, quote.spread, quote.mid) so Postgres fills those in itself.
func NewTableWriter[T any](
	table string, columns []string, toRow func(T) []any,
	pool Pool, cfg BatchConfig, clk clock.Clock, metrics Metrics, logger *slog.Logger,
) *TableWriter[T] {
	cfg.withDefaults()
	if clk == nil {
		clk = clock.Real()
	}
	if metrics == nil {
		metrics = nopMetrics{}
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &TableWriter[T]{
		table: table, pool: pool, toRow: toRow, columns: columns,
		cfg: cfg, clk: clk, metrics: metrics, logger: logger,
		flushNow: make(chan struct{}, 1),
	}
}

// Add buffers one row, triggering an async flush once BatchRows is reached
// and shedding once BufferRows is reached. It never blocks on I/O.
func (w *TableWriter[T]) Add(row T) {
	w.mu.Lock()
	if len(w.buf) >= w.cfg.BufferRows {
		w.mu.Unlock()
		w.metrics.DBShed(1)
		w.logger.Error("shedding row: database write buffer is full",
			slog.String("table", w.table), slog.Int("buffer_rows", w.cfg.BufferRows))
		return
	}
	w.buf = append(w.buf, row)
	full := len(w.buf) >= w.cfg.BatchRows
	w.mu.Unlock()
	w.metrics.DBBuffered(1)

	if full {
		select {
		case w.flushNow <- struct{}{}:
		default: // a flush is already pending; this one will pick up the rest
		}
	}
}

// Run drives time-based and size-triggered flushing until ctx is cancelled,
// performing one best-effort final flush on the way out.
func (w *TableWriter[T]) Run(ctx context.Context) error {
	ticker := w.clk.NewTicker(w.cfg.BatchInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			_ = w.Flush(context.WithoutCancel(ctx))
			return ctx.Err()
		case <-ticker.C():
			_ = w.Flush(ctx)
		case <-w.flushNow:
			_ = w.Flush(ctx)
		}
	}
}

// Flush attempts to write the current buffer. It is exported so tests and a
// graceful shutdown can drive it deterministically without waiting on Run's
// ticker.
func (w *TableWriter[T]) Flush(ctx context.Context) error {
	w.mu.Lock()
	if len(w.buf) == 0 {
		w.mu.Unlock()
		return nil
	}
	rows := w.buf
	w.buf = make([]T, 0, cap(rows))
	w.mu.Unlock()

	start := w.clk.Now()
	src := &sliceCopySource[T]{rows: rows, toRow: w.toRow, index: -1}
	_, err := w.pool.CopyFrom(ctx, pgx.Identifier(splitSchema(w.table)), w.columns, src)
	dur := w.clk.Now().Sub(start)

	if err != nil {
		w.mu.Lock()
		// Put the failed batch back in front of anything that arrived while
		// this attempt was in flight, so ordering and eventual delivery are
		// both preserved for the retry (see the type doc for the bound this
		// implies).
		merged := make([]T, 0, len(rows)+len(w.buf))
		merged = append(merged, rows...)
		merged = append(merged, w.buf...)
		w.buf = merged
		w.mu.Unlock()
		w.logger.Error("copyfrom batch failed, retaining rows for retry",
			slog.String("table", w.table), slog.Int("rows", len(rows)), slog.Any("error", err))
		return fmt.Errorf("copyfrom %s: %w", w.table, err)
	}

	w.metrics.DBBatchRows(len(rows), dur)
	w.metrics.DBBuffered(-len(rows))
	return nil
}

// Pending reports how many rows are currently buffered, for tests and for a
// diagnostics endpoint.
func (w *TableWriter[T]) Pending() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.buf)
}

// sliceCopySource adapts a []T plus a per-row projector to pgx.CopyFromSource
// without materialising every row's []any up front.
type sliceCopySource[T any] struct {
	rows  []T
	toRow func(T) []any
	index int
	err   error
}

func (s *sliceCopySource[T]) Next() bool {
	s.index++
	return s.index < len(s.rows)
}
func (s *sliceCopySource[T]) Values() ([]any, error) {
	return s.toRow(s.rows[s.index]), nil
}
func (s *sliceCopySource[T]) Err() error { return s.err }

// splitSchema turns "market.trade" into ["market", "trade"] for
// pgx.Identifier, which CopyFrom quotes and joins itself.
func splitSchema(qualified string) []string {
	for i := 0; i < len(qualified); i++ {
		if qualified[i] == '.' {
			return []string{qualified[:i], qualified[i+1:]}
		}
	}
	return []string{qualified}
}

// ── table-specific constructors and row projectors ──────────────────────────
// Column lists match db/migrations/0004_market_data_timeseries.sql exactly,
// excluding GENERATED columns (quote.spread, quote.mid) and DEFAULT-only
// columns (ingested_at everywhere), both of which Postgres fills in itself.

// NewTradeWriter builds a TableWriter for market.trade.
func NewTradeWriter(pool Pool, cfg BatchConfig, clk clock.Clock, metrics Metrics, logger *slog.Logger) *TableWriter[model.Trade] {
	columns := []string{"ts", "instrument_id", "price", "size", "trade_id", "venue_id", "aggressor", "conditions", "exchange_ts", "quality"}
	toRow := func(t model.Trade) []any {
		return []any{
			t.TS, t.InstrumentID, t.Price, t.Size,
			nullableString(t.TradeID), t.VenueID, nullableSide(t.Aggressor),
			nonNilStrings(t.Conditions), nullableTime(t.ExchangeTS), string(orDefaultQuality(t.Quality)),
		}
	}
	return NewTableWriter("market.trade", columns, toRow, pool, cfg, clk, metrics, logger)
}

// NewQuoteWriter builds a TableWriter for market.quote.
func NewQuoteWriter(pool Pool, cfg BatchConfig, clk clock.Clock, metrics Metrics, logger *slog.Logger) *TableWriter[model.Quote] {
	columns := []string{"ts", "instrument_id", "bid_price", "bid_size", "ask_price", "ask_size", "bid_venue_id", "ask_venue_id", "exchange_ts"}
	toRow := func(q model.Quote) []any {
		return []any{
			q.TS, q.InstrumentID, nullableDecimal(q.BidPrice), nullableDecimal(q.BidSize),
			nullableDecimal(q.AskPrice), nullableDecimal(q.AskSize),
			nullableVenue(q.BidVenueID), nullableVenue(q.AskVenueID), nullableTime(q.ExchangeTS),
		}
	}
	return NewTableWriter("market.quote", columns, toRow, pool, cfg, clk, metrics, logger)
}

// NewBarWriter builds a TableWriter for market.bar_1m.
func NewBarWriter(pool Pool, cfg BatchConfig, clk clock.Clock, metrics Metrics, logger *slog.Logger) *TableWriter[model.Bar] {
	columns := []string{"ts", "instrument_id", "open", "high", "low", "close", "volume", "trade_count", "vwap", "session", "quality", "source"}
	toRow := func(b model.Bar) []any {
		session := b.Session
		if session == "" {
			session = model.SessionRegular
		}
		return []any{
			b.TS, b.InstrumentID, b.Open, b.High, b.Low, b.Close, b.Volume,
			nullableTradeCount(b.TradeCount), nullableDecimal(b.VWAP),
			string(session), string(orDefaultQuality(b.Quality)), orDefault(b.Source, "aggregated"),
		}
	}
	return NewTableWriter("market.bar_1m", columns, toRow, pool, cfg, clk, metrics, logger)
}

// NewBookSnapshotWriter builds a TableWriter for market.book_snapshot.
func NewBookSnapshotWriter(pool Pool, cfg BatchConfig, clk clock.Clock, metrics Metrics, logger *slog.Logger) *TableWriter[model.BookSnapshot] {
	columns := []string{"ts", "instrument_id", "sequence", "bids", "asks", "depth_levels", "imbalance_l1", "imbalance_l5"}
	toRow := func(s model.BookSnapshot) []any {
		bids, _ := json.Marshal(levelsOrEmpty(s.Bids))
		asks, _ := json.Marshal(levelsOrEmpty(s.Asks))
		return []any{
			s.TS, s.InstrumentID, nullableSequence(s.Sequence),
			json.RawMessage(bids), json.RawMessage(asks), s.DepthLevels,
			nullableDecimal(s.ImbalanceL1), nullableDecimal(s.ImbalanceL5),
		}
	}
	return NewTableWriter("market.book_snapshot", columns, toRow, pool, cfg, clk, metrics, logger)
}

// FeedHealthRow and DataGap mirror health.FeedHealthRow/DataGap. Defined here
// rather than imported from internal/health so this package's public surface
// does not force every caller of the timescale writers to depend on the
// health package's Tracker just to get its row shape.
type FeedHealthRow struct {
	TS             time.Time
	Vendor         string
	Feed           string
	Messages       int64
	Bytes          int64
	GapsDetected   int32
	SequenceResets int32
	P50LatencyMs   *int32
	P99LatencyMs   *int32
	MaxLatencyMs   *int32
	Reconnects     int32
	LastError      string
}

// DataGap mirrors market.data_gap.
type DataGap struct {
	InstrumentID uuid.UUID
	Feed         string
	GapStart     time.Time
	GapEnd       time.Time
	ExpectedRows int32
	ActualRows   int32
}

// NewFeedHealthWriter builds a TableWriter for market.feed_health.
func NewFeedHealthWriter(pool Pool, cfg BatchConfig, clk clock.Clock, metrics Metrics, logger *slog.Logger) *TableWriter[FeedHealthRow] {
	columns := []string{"ts", "vendor", "feed", "messages", "bytes", "gaps_detected", "sequence_resets", "p50_latency_ms", "p99_latency_ms", "max_latency_ms", "reconnects", "last_error"}
	toRow := func(r FeedHealthRow) []any {
		return []any{
			r.TS, r.Vendor, r.Feed, r.Messages, r.Bytes, r.GapsDetected, r.SequenceResets,
			nullableInt32Ptr(r.P50LatencyMs), nullableInt32Ptr(r.P99LatencyMs), nullableInt32Ptr(r.MaxLatencyMs),
			r.Reconnects, nullableString(r.LastError),
		}
	}
	return NewTableWriter("market.feed_health", columns, toRow, pool, cfg, clk, metrics, logger)
}

// NewDataGapWriter builds a TableWriter for market.data_gap.
func NewDataGapWriter(pool Pool, cfg BatchConfig, clk clock.Clock, metrics Metrics, logger *slog.Logger) *TableWriter[DataGap] {
	columns := []string{"instrument_id", "feed", "gap_start", "gap_end", "expected_rows", "actual_rows"}
	toRow := func(g DataGap) []any {
		return []any{g.InstrumentID, g.Feed, g.GapStart, g.GapEnd, nullableInt32(g.ExpectedRows), nullableInt32(g.ActualRows)}
	}
	return NewTableWriter("market.data_gap", columns, toRow, pool, cfg, clk, metrics, logger)
}

func nullableInt32Ptr(p *int32) any {
	if p == nil {
		return nil
	}
	return *p
}

func nullableInt32(n int32) any {
	if n == 0 {
		return nil
	}
	return n
}

func levelsOrEmpty(lvls []model.BookLevel) []model.BookLevel {
	if lvls == nil {
		return []model.BookLevel{}
	}
	return lvls
}

func nullableString(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nullableSide(s model.Side) any {
	if s == model.SideUnspecified {
		return nil
	}
	return string(s)
}

func nonNilStrings(ss []string) []string {
	if ss == nil {
		return []string{}
	}
	return ss
}

func nullableTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t
}

func nullableDecimal(d interface{ IsZero() bool }) any {
	if d.IsZero() {
		return nil
	}
	return d
}

func nullableVenue(v int16) any {
	if v == 0 {
		return nil
	}
	return v
}

func nullableTradeCount(n int32) any {
	if n == 0 {
		return nil
	}
	return n
}

func nullableSequence(seq int64) any {
	if seq == 0 {
		return nil
	}
	return seq
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func orDefaultQuality(q model.Quality) model.Quality {
	if q == "" {
		return model.QualityVendor
	}
	return q
}
