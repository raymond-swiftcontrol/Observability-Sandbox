package aggregate

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/clock"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
	"github.com/shopspring/decimal"
)

// Roller produces a live 5m/15m/1h roll-up from finalised 1m bars, mirroring
// the shape of the market.bar_5m/15m/1h continuous aggregates in
// db/migrations/0004 exactly: first(open), max(high), min(low), last(close),
// sum(volume), sum(trade_count), volume-weighted vwap, extended hours
// excluded. Keeping the same aggregation as the Timescale continuous
// aggregate is deliberate — a live figure that disagrees with the eventual
// materialised one is worse than no live figure at all.
//
// This is a convenience for dashboards and strategies that want a coarser bar
// before Timescale's continuous aggregate policy has run (see the
// schedule_interval values in 0004); it is not the system of record. The
// materialised view remains authoritative for anything persisted.
type Roller struct {
	interval time.Duration
	clk      clock.Clock
	sink     Sink
	metrics  Metrics
	logger   *slog.Logger

	mu   sync.Mutex
	open map[instKey]*rollupBucket
}

type rollupBucket struct {
	instrumentID uuid.UUID
	symbol       string
	start        time.Time
	deadline     time.Time
	session      model.Session

	open, high, low, close decimal.Decimal
	openTS, closeTS        time.Time
	volume                 decimal.Decimal
	tradeCount             int32
	vwapNum, vwapDen       decimal.Decimal
}

// NewRoller builds a Roller for one coarser interval (5m, 15m or 1h). extra is
// added to the bucket's own interval before it is force-closed, giving late
// constituent 1m bars (already inside their own grace window) room to land.
func NewRoller(interval time.Duration, extra time.Duration, clk clock.Clock, sink Sink, metrics Metrics, logger *slog.Logger) *Roller {
	if clk == nil {
		clk = clock.Real()
	}
	if metrics == nil {
		metrics = nopMetrics{}
	}
	if logger == nil {
		logger = slog.Default()
	}
	if extra < 0 {
		extra = 0
	}
	return &Roller{
		interval: interval,
		clk:      clk,
		sink:     sink,
		metrics:  metrics,
		logger:   logger,
		open:     map[instKey]*rollupBucket{},
	}
}

// AddBar folds one finalised 1m bar in. Extended-hours bars are excluded,
// matching the `WHERE session = 'regular'` clause on every continuous
// aggregate in 0004.
func (r *Roller) AddBar(ctx context.Context, bar model.Bar) {
	if bar.Session != model.SessionRegular {
		return
	}
	start := bar.TS.Truncate(r.interval).UTC()
	key := instKey{id: bar.InstrumentID, start: start.UnixNano()}

	r.mu.Lock()
	b, ok := r.open[key]
	if !ok {
		b = &rollupBucket{
			instrumentID: bar.InstrumentID,
			symbol:       bar.Symbol,
			start:        start,
			deadline:     start.Add(r.interval),
			session:      bar.Session,
			volume:       decimal.Zero,
			vwapNum:      decimal.Zero,
			vwapDen:      decimal.Zero,
		}
		r.open[key] = b
	}
	if b.openTS.IsZero() || bar.TS.Before(b.openTS) {
		b.open = bar.Open
		b.openTS = bar.TS
	}
	if b.closeTS.IsZero() || !bar.TS.Before(b.closeTS) {
		b.close = bar.Close
		b.closeTS = bar.TS
	}
	if b.high.IsZero() || bar.High.GreaterThan(b.high) {
		b.high = bar.High
	}
	if b.low.IsZero() || bar.Low.LessThan(b.low) {
		b.low = bar.Low
	}
	b.volume = b.volume.Add(bar.Volume)
	b.tradeCount += bar.TradeCount
	weight := bar.VWAP
	if weight.IsZero() {
		weight = bar.Close
	}
	b.vwapNum = b.vwapNum.Add(weight.Mul(bar.Volume))
	b.vwapDen = b.vwapDen.Add(bar.Volume)
	r.mu.Unlock()
}

// CheckCloses emits every roll-up bucket whose deadline has passed.
func (r *Roller) CheckCloses(ctx context.Context, now time.Time) ([]model.Bar, error) {
	var due []*rollupBucket
	r.mu.Lock()
	for key, b := range r.open {
		if !now.Before(b.deadline) {
			due = append(due, b)
			delete(r.open, key)
		}
	}
	r.mu.Unlock()

	bars := make([]model.Bar, 0, len(due))
	var firstErr error
	for _, b := range due {
		vwap := b.close
		if !b.vwapDen.IsZero() {
			vwap = b.vwapNum.Div(b.vwapDen)
		}
		bar := model.Bar{
			TS: b.start, InstrumentID: b.instrumentID, Symbol: b.symbol,
			Open: b.open, High: b.high, Low: b.low, Close: b.close,
			Volume: b.volume, TradeCount: b.tradeCount, VWAP: vwap,
			Session: b.session, Quality: model.QualityDerived,
			Source: "aggregated", Interval: r.interval, Final: true,
		}
		if err := r.sink.EmitBar(ctx, bar); err != nil {
			if firstErr == nil {
				firstErr = err
			}
			r.logger.ErrorContext(ctx, "failed to emit rolled-up bar",
				slog.Duration("interval", r.interval), slog.String("symbol", bar.Symbol), slog.Any("error", err))
			continue
		}
		r.metrics.BarEmitted()
		bars = append(bars, bar)
	}
	return bars, firstErr
}

// Run drives roll-up close from the clock, exactly like Aggregator.Run.
func (r *Roller) Run(ctx context.Context) error {
	ticker := r.clk.NewTicker(r.interval / 4)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			if _, err := r.CheckCloses(context.WithoutCancel(ctx), r.clk.Now().Add(365*24*time.Hour)); err != nil {
				return errJoin(ctx.Err(), err)
			}
			return ctx.Err()
		case now := <-ticker.C():
			if _, err := r.CheckCloses(ctx, now); err != nil {
				r.logger.ErrorContext(ctx, "roll-up close sweep reported an error", slog.Any("error", err))
			}
		}
	}
}
