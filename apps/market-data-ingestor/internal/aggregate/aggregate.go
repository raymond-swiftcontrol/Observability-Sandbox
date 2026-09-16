// Package aggregate turns trade prints into OHLCV bars.
//
// The one rule that shapes everything else here: a bar's close is a clock
// event, not a data event. db/migrations/0004 stores 1m bars as the only
// ingested intraday resolution and every coarser resolution is derived from
// them, so a bar that never closes because its symbol went quiet starves the
// whole roll-up chain. The Aggregator therefore drives bucket close from a
// ticker (see Run) and treats "no trade arrived" as a reason to check the
// clock, never as a reason to wait.
package aggregate

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/calendar"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/clock"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
	"github.com/shopspring/decimal"
)

// Late-tick dispositions, used as the metric label vocabulary.
const (
	DispositionFolded  = "folded"
	DispositionDropped = "dropped"
)

// Config tunes the aggregator. It mirrors config.AggregateConfig field for
// field so callers can pass it through unchanged.
type Config struct {
	// Interval is the ingested bar resolution. 1 minute in production; tests
	// use smaller intervals to keep fixtures readable.
	Interval time.Duration
	// Grace is how long after a bucket's nominal close a trade for that bucket
	// is still folded in. Beyond it the trade is counted as late-dropped
	// rather than silently mutating a bar a consumer may already have read.
	Grace time.Duration
	// CloseCheck is the ticker period that drives bucket close. It must be
	// shorter than Grace or a bucket can sit finalised-but-unclosed for up to
	// one extra CloseCheck period; config.Load enforces CloseCheck < Interval.
	CloseCheck time.Duration
}

func (c *Config) withDefaults() {
	if c.Interval <= 0 {
		c.Interval = time.Minute
	}
	if c.Grace <= 0 {
		c.Grace = 3 * time.Second
	}
	if c.CloseCheck <= 0 {
		c.CloseCheck = time.Second
	}
}

// Sink receives finalised bars.
type Sink interface {
	EmitBar(ctx context.Context, bar model.Bar) error
}

// SinkFunc adapts a function to Sink.
type SinkFunc func(ctx context.Context, bar model.Bar) error

// EmitBar implements Sink.
func (f SinkFunc) EmitBar(ctx context.Context, bar model.Bar) error { return f(ctx, bar) }

// Metrics receives the aggregator's counters. Kept as a narrow interface
// (rather than *telemetry.Metrics directly) so the package tests without a
// meter provider, matching the convention in internal/normalize.
type Metrics interface {
	BarEmitted()
	LateTick(disposition string)
}

type nopMetrics struct{}

func (nopMetrics) BarEmitted()     {}
func (nopMetrics) LateTick(string) {}

// bucket is one instrument's in-progress bar.
type bucket struct {
	instrumentID uuid.UUID
	symbol       string
	start        time.Time // bucket OPEN time
	nominalClose time.Time // start + Interval
	deadline     time.Time // nominalClose + Grace: when the ticker finalises it

	open, high, low, close decimal.Decimal
	openTS, closeTS        time.Time
	volume                 decimal.Decimal
	tradeCount             int32
	vwapNum                decimal.Decimal // Σ price*size
	vwapDen                decimal.Decimal // Σ size
}

func newBucket(instrumentID uuid.UUID, symbol string, start time.Time, interval, grace time.Duration) *bucket {
	nominalClose := start.Add(interval)
	return &bucket{
		instrumentID: instrumentID,
		symbol:       symbol,
		start:        start,
		nominalClose: nominalClose,
		deadline:     nominalClose.Add(grace),
		volume:       decimal.Zero,
		vwapNum:      decimal.Zero,
		vwapDen:      decimal.Zero,
	}
}

// fold applies one trade's contribution to the bucket. Open and close are
// chosen by exchange timestamp, not by arrival order, so a trade that arrives
// out of order still lands in the right place in the candle.
func (b *bucket) fold(t *model.Trade) {
	if b.openTS.IsZero() || t.TS.Before(b.openTS) {
		b.open = t.Price
		b.openTS = t.TS
	}
	if b.closeTS.IsZero() || !t.TS.Before(b.closeTS) {
		b.close = t.Price
		b.closeTS = t.TS
	}
	if b.high.IsZero() || t.Price.GreaterThan(b.high) {
		b.high = t.Price
	}
	if b.low.IsZero() || t.Price.LessThan(b.low) {
		b.low = t.Price
	}
	b.volume = b.volume.Add(t.Size)
	b.tradeCount++
	b.vwapNum = b.vwapNum.Add(t.Price.Mul(t.Size))
	b.vwapDen = b.vwapDen.Add(t.Size)
}

// vwap returns the volume-weighted average price, or Close when there was no
// volume to weight (defensive; fold always adds positive size in practice).
func (b *bucket) vwap() decimal.Decimal {
	if b.vwapDen.IsZero() {
		return b.close
	}
	return b.vwapNum.Div(b.vwapDen)
}

func (b *bucket) toBar(session model.Session) model.Bar {
	return model.Bar{
		TS:           b.start,
		InstrumentID: b.instrumentID,
		Symbol:       b.symbol,
		Open:         b.open,
		High:         b.high,
		Low:          b.low,
		Close:        b.close,
		Volume:       b.volume,
		TradeCount:   b.tradeCount,
		VWAP:         b.vwap(),
		Session:      session,
		Quality:      model.QualityDerived,
		Source:       "aggregated",
		Interval:     b.nominalClose.Sub(b.start),
		Final:        true,
	}
}

type instKey struct {
	id    uuid.UUID
	start int64 // UnixNano of bucket start; time.Time is not a map key here to keep zero-alloc comparisons cheap
}

// Aggregator accumulates trades into bars, one open bucket per (instrument,
// bucket start), and closes them on a clock tick.
type Aggregator struct {
	cfg     Config
	clk     clock.Clock
	cal     calendar.Calendar
	sink    Sink
	metrics Metrics
	logger  *slog.Logger

	roller *Roller

	mu   sync.Mutex
	open map[instKey]*bucket
}

// New builds an Aggregator. cal and sink must not be nil; a nil clock, logger
// or metrics fall back to sane defaults.
func New(cfg Config, clk clock.Clock, cal calendar.Calendar, sink Sink, metrics Metrics, logger *slog.Logger) *Aggregator {
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
	return &Aggregator{
		cfg:     cfg,
		clk:     clk,
		cal:     cal,
		sink:    sink,
		metrics: metrics,
		logger:  logger,
		open:    map[instKey]*bucket{},
	}
}

// WithRollup attaches a live roll-up chain fed by this aggregator's finalised
// 1m bars. Returns the Aggregator for chaining.
func (a *Aggregator) WithRollup(r *Roller) *Aggregator {
	a.roller = r
	return a
}

// Ingest dispatches one canonical event. Only trades feed the bar; every
// other kind is a no-op because OHLCV is defined over the trade tape, not the
// quote stream (see db/migrations/0004 bar_1m comments).
func (a *Aggregator) Ingest(ctx context.Context, ev model.Event) error {
	if ev.Kind != model.KindTrade {
		return nil
	}
	return a.AddTrade(ctx, ev.Trade)
}

// AddTrade folds one trade into its bucket, opening a new bucket if needed.
// A trade whose bucket has already closed and passed its grace deadline is
// counted as late-dropped rather than silently ignored.
func (a *Aggregator) AddTrade(ctx context.Context, t *model.Trade) error {
	if t == nil {
		return fmt.Errorf("aggregate: nil trade")
	}
	start := t.TS.Truncate(a.cfg.Interval).UTC()
	key := instKey{id: t.InstrumentID, start: start.UnixNano()}
	now := a.clk.Now()

	a.mu.Lock()
	b, ok := a.open[key]
	if !ok {
		deadline := start.Add(a.cfg.Interval).Add(a.cfg.Grace)
		if !now.Before(deadline) {
			// The bucket this trade belongs to has already had its close
			// deadline pass. There is nothing to fold into: count it and move
			// on rather than opening a bucket that will never be observed by
			// the close ticker's next sweep in time.
			a.mu.Unlock()
			a.metrics.LateTick(DispositionDropped)
			a.logger.WarnContext(ctx, "late trade dropped past grace window",
				slog.String("instrument_id", t.InstrumentID.String()),
				slog.Time("bucket_start", start),
				slog.Time("now", now))
			return nil
		}
		b = newBucket(t.InstrumentID, t.Symbol, start, a.cfg.Interval, a.cfg.Grace)
		a.open[key] = b
	}
	late := !now.Before(b.nominalClose)
	b.fold(t)
	a.mu.Unlock()

	if late {
		a.metrics.LateTick(DispositionFolded)
	}
	return nil
}

// CheckCloses finalises and emits every bucket whose deadline has passed as
// of now. It is exported so Run's ticker loop and tests share exactly one
// closing path — Run is a thin wrapper that calls this on every tick.
func (a *Aggregator) CheckCloses(ctx context.Context, now time.Time) ([]model.Bar, error) {
	var due []*bucket
	a.mu.Lock()
	for key, b := range a.open {
		if !now.Before(b.deadline) {
			due = append(due, b)
			delete(a.open, key)
		}
	}
	a.mu.Unlock()

	bars := make([]model.Bar, 0, len(due))
	var firstErr error
	for _, b := range due {
		session := model.SessionRegular
		if a.cal != nil {
			session = a.cal.SessionFor(b.instrumentID, b.start)
		}
		bar := b.toBar(session)
		if err := a.sink.EmitBar(ctx, bar); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("emit bar %s@%s: %w", bar.Symbol, bar.TS, err)
			}
			a.logger.ErrorContext(ctx, "failed to emit bar",
				slog.String("symbol", bar.Symbol), slog.Time("ts", bar.TS), slog.Any("error", err))
			continue
		}
		a.metrics.BarEmitted()
		bars = append(bars, bar)
		if a.roller != nil {
			a.roller.AddBar(ctx, bar)
		}
	}
	return bars, firstErr
}

// Run drives bucket close from the clock. It blocks until ctx is cancelled,
// at which point it flushes every still-open bucket (see Flush) so a
// graceful shutdown does not discard a partially-formed bar silently — the
// emitted bar simply carries whatever the bucket had accumulated so far.
func (a *Aggregator) Run(ctx context.Context) error {
	ticker := a.clk.NewTicker(a.cfg.CloseCheck)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			if _, err := a.Flush(context.WithoutCancel(ctx)); err != nil {
				return errJoin(ctx.Err(), err)
			}
			return ctx.Err()
		case <-ticker.C():
			// Sweep against the clock's current reading, NOT the timestamp the
			// tick carries. A ticker channel is buffered by one and sent to
			// non-blockingly, so under load — or after any pause longer than
			// CloseCheck — the tick we receive can be arbitrarily stale. Using
			// that stale timestamp would leave every bucket whose deadline
			// fell in the gap open, which is precisely the quiet-symbol case
			// this sweep exists to handle.
			if _, err := a.CheckCloses(ctx, a.clk.Now()); err != nil {
				a.logger.ErrorContext(ctx, "bar close sweep reported an error", slog.Any("error", err))
			}
		}
	}
}

// Flush finalises and emits every open bucket regardless of its deadline. It
// is what a graceful shutdown calls so an in-flight bar is not lost, just
// closed early.
func (a *Aggregator) Flush(ctx context.Context) ([]model.Bar, error) {
	farFuture := a.clk.Now().Add(365 * 24 * time.Hour)
	return a.CheckCloses(ctx, farFuture)
}

// OpenCount reports how many buckets are currently in progress, for tests and
// for a diagnostics endpoint.
func (a *Aggregator) OpenCount() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.open)
}

func errJoin(a, b error) error {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	return fmt.Errorf("%w; %w", a, b)
}
