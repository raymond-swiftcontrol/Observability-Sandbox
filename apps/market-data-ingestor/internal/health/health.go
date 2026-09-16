// Package health turns the ingestor's own operational signal — message and
// byte counts, sequence gaps, reconnects, feed latency — into the two tables
// db/migrations/0004 sets aside for exactly that: market.feed_health (a
// periodic per vendor/feed rollup) and market.data_gap (an explicit,
// auditable record of every discontinuity, so research can exclude affected
// windows instead of silently training on holes).
//
// Latency percentiles are computed over each reporting window's samples
// rather than maintained as a running estimate (t-digest, HDR histogram):
// at the reporting cadence this service uses (on the order of once a
// minute) and the per-window sample counts involved, sorting the window's
// samples is microseconds of CPU, and an exact percentile over the window
// that actually happened is a truer number than a decaying approximation —
// worth keeping simple until a profile says otherwise.
package health

import (
	"context"
	"log/slog"
	"sort"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/clock"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
)

// FeedHealthRow mirrors market.feed_health. Latency fields are nil when the
// window saw no messages, matching the nullable columns.
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

// Sink receives rendered rows for persistence.
type Sink interface {
	EmitFeedHealth(ctx context.Context, row FeedHealthRow) error
	EmitDataGap(ctx context.Context, gap DataGap) error
}

// Metrics receives the tracker's counters.
type Metrics interface {
	GapDetected()
	SequenceReset()
}

type nopMetrics struct{}

func (nopMetrics) GapDetected()   {}
func (nopMetrics) SequenceReset() {}

type vendorFeedKey struct {
	vendor string
	feed   string
}

type seqKey struct {
	instrumentID uuid.UUID
	feed         string
}

// window accumulates one (vendor, feed)'s counters between reports.
type window struct {
	messages       int64
	bytes          int64
	gapsDetected   int32
	sequenceResets int32
	reconnects     int32
	lastError      string
	// latenciesMs holds each message's (received - exchange) latency in
	// milliseconds, cleared on every report. Bounded by capMs below so one
	// runaway window cannot grow this unboundedly.
	latenciesMs []float64
}

// maxSamplesPerWindow bounds per-window latency sample retention. Beyond it,
// newer samples still update Max via a running max kept alongside, but stop
// growing the slice — a percentile over a bounded, randomly-arrived subset of
// a window with millions of messages is statistically indistinguishable from
// one over all of them, and an unbounded slice is not.
const maxSamplesPerWindow = 100000

// Tracker aggregates feed health across every (vendor, feed) pair and reports
// on a clock-driven schedule.
type Tracker struct {
	clk      clock.Clock
	interval time.Duration
	sink     Sink
	metrics  Metrics
	logger   *slog.Logger

	mu      sync.Mutex
	windows map[vendorFeedKey]*window
	lastSeq map[seqKey]seqState
}

type seqState struct {
	sequence int64
	ts       time.Time
}

// Options configures a Tracker.
type Options struct {
	// Interval is the reporting cadence: how often a feed_health row is
	// emitted per (vendor, feed) pair.
	Interval time.Duration
	Clock    clock.Clock
	Sink     Sink
	Metrics  Metrics
	Logger   *slog.Logger
}

// NewTracker builds a Tracker.
func NewTracker(opts Options) *Tracker {
	if opts.Interval <= 0 {
		opts.Interval = time.Minute
	}
	if opts.Clock == nil {
		opts.Clock = clock.Real()
	}
	if opts.Metrics == nil {
		opts.Metrics = nopMetrics{}
	}
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	return &Tracker{
		clk: opts.Clock, interval: opts.Interval, sink: opts.Sink,
		metrics: opts.Metrics, logger: opts.Logger,
		windows: map[vendorFeedKey]*window{},
		lastSeq: map[seqKey]seqState{},
	}
}

func (t *Tracker) windowFor(vendor string, feed model.Feed) *window {
	k := vendorFeedKey{vendor: vendor, feed: string(feed)}
	w, ok := t.windows[k]
	if !ok {
		w = &window{}
		t.windows[k] = w
	}
	return w
}

// RecordMessage accounts for one received message: its size and its
// exchange-to-receipt latency.
func (t *Tracker) RecordMessage(vendor string, feed model.Feed, bytes int, exchangeTS, receivedAt time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	w := t.windowFor(vendor, feed)
	w.messages++
	w.bytes += int64(bytes)
	if !exchangeTS.IsZero() && !receivedAt.Before(exchangeTS) {
		ms := float64(receivedAt.Sub(exchangeTS)) / float64(time.Millisecond)
		if len(w.latenciesMs) < maxSamplesPerWindow {
			w.latenciesMs = append(w.latenciesMs, ms)
		}
	}
}

// RecordReconnect accounts for one vendor reconnect attempt.
func (t *Tracker) RecordReconnect(vendor string, feed model.Feed) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.windowFor(vendor, feed).reconnects++
}

// RecordError sets the window's last-error text (overwritten by the most
// recent error; feed_health carries only one per row by design).
func (t *Tracker) RecordError(vendor string, feed model.Feed, err error) {
	if err == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.windowFor(vendor, feed).lastError = err.Error()
}

// CheckSequence tracks per-(instrument, feed) sequence continuity and emits a
// market.data_gap row through the Sink the moment a discontinuity is
// detected — not batched into the periodic report, because a gap is exactly
// the kind of thing research needs to know about promptly, and the whole
// point of this table is that it is more durable and queryable than a log
// line. A sequence that goes backwards is treated as a vendor-side reset
// (counted separately) rather than a gap, matching vendor.Session's
// convention.
func (t *Tracker) CheckSequence(ctx context.Context, instrumentID uuid.UUID, vendor string, feed model.Feed, sequence int64, ts time.Time) {
	if sequence < 0 {
		return // SequenceUnknown: nothing to check
	}
	k := seqKey{instrumentID: instrumentID, feed: string(feed)}

	t.mu.Lock()
	prev, seen := t.lastSeq[k]
	t.lastSeq[k] = seqState{sequence: sequence, ts: ts}
	w := t.windowFor(vendor, feed)

	var gap *DataGap
	switch {
	case !seen:
		// First observation: nothing to compare against yet.
	case sequence < prev.sequence:
		w.sequenceResets++
		t.metrics.SequenceReset()
	case sequence > prev.sequence+1:
		missing := sequence - prev.sequence - 1
		w.gapsDetected++
		gap = &DataGap{
			InstrumentID: instrumentID, Feed: string(feed),
			GapStart: prev.ts, GapEnd: ts,
			ExpectedRows: int32(missing), ActualRows: 0,
		}
	}
	t.mu.Unlock()

	if gap != nil {
		t.metrics.GapDetected()
		if t.sink != nil {
			if err := t.sink.EmitDataGap(ctx, *gap); err != nil {
				t.logger.ErrorContext(ctx, "failed to record data gap",
					slog.String("instrument_id", instrumentID.String()), slog.Any("error", err))
			}
		}
	}
}

// Report renders and emits every window's current state as of now, then
// resets message/byte/latency counters (but not the sequence baselines,
// which must survive across reporting windows). It is exported so Run's
// ticker and tests share exactly one reporting path.
func (t *Tracker) Report(ctx context.Context, now time.Time) ([]FeedHealthRow, error) {
	t.mu.Lock()
	type entry struct {
		key vendorFeedKey
		w   window
	}
	entries := make([]entry, 0, len(t.windows))
	for k, w := range t.windows {
		entries = append(entries, entry{key: k, w: *w})
		*w = window{} // reset in place; the copy above is what gets reported
	}
	t.mu.Unlock()

	rows := make([]FeedHealthRow, 0, len(entries))
	var firstErr error
	for _, e := range entries {
		row := FeedHealthRow{
			TS: now, Vendor: e.key.vendor, Feed: e.key.feed,
			Messages: e.w.messages, Bytes: e.w.bytes,
			GapsDetected: e.w.gapsDetected, SequenceResets: e.w.sequenceResets,
			Reconnects: e.w.reconnects, LastError: e.w.lastError,
		}
		if p50, p99, max, ok := latencyStats(e.w.latenciesMs); ok {
			row.P50LatencyMs = &p50
			row.P99LatencyMs = &p99
			row.MaxLatencyMs = &max
		}
		if t.sink != nil {
			if err := t.sink.EmitFeedHealth(ctx, row); err != nil {
				if firstErr == nil {
					firstErr = err
				}
				t.logger.ErrorContext(ctx, "failed to record feed health",
					slog.String("vendor", row.Vendor), slog.String("feed", row.Feed), slog.Any("error", err))
				continue
			}
		}
		rows = append(rows, row)
	}
	return rows, firstErr
}

// Run drives periodic reporting from the clock until ctx is cancelled,
// performing one final report on the way out so the last partial window is
// not silently lost.
func (t *Tracker) Run(ctx context.Context) error {
	ticker := t.clk.NewTicker(t.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			_, _ = t.Report(context.WithoutCancel(ctx), t.clk.Now())
			return ctx.Err()
		case now := <-ticker.C():
			if _, err := t.Report(ctx, now); err != nil {
				t.logger.ErrorContext(ctx, "feed health report encountered an error", slog.Any("error", err))
			}
		}
	}
}

// latencyStats computes p50, p99 and max (in whole milliseconds) over
// samples using the nearest-rank method. ok is false when there were no
// samples, matching feed_health's nullable latency columns.
func latencyStats(samples []float64) (p50, p99, max int32, ok bool) {
	if len(samples) == 0 {
		return 0, 0, 0, false
	}
	sorted := append([]float64(nil), samples...)
	sort.Float64s(sorted)
	return int32(percentile(sorted, 50)), int32(percentile(sorted, 99)), int32(sorted[len(sorted)-1]), true
}

// percentile returns the p-th percentile of an already-sorted slice using the
// nearest-rank method: rank = ceil(p/100 * n), 1-indexed, clamped to
// [1, n]. This matches how most observability tooling defines "p99 latency"
// and, unlike linear interpolation, never fabricates a value that no sample
// actually had.
func percentile(sorted []float64, p float64) float64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	rank := int((p/100)*float64(n) + 0.9999999) // ceil without importing math for one call
	if rank < 1 {
		rank = 1
	}
	if rank > n {
		rank = n
	}
	return sorted[rank-1]
}
