package health

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/clock"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
)

type collectingSink struct {
	mu    sync.Mutex
	rows  []FeedHealthRow
	gaps  []DataGap
}

func (s *collectingSink) EmitFeedHealth(_ context.Context, row FeedHealthRow) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.rows = append(s.rows, row)
	return nil
}
func (s *collectingSink) EmitDataGap(_ context.Context, gap DataGap) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gaps = append(s.gaps, gap)
	return nil
}
func (s *collectingSink) snapshotGaps() []DataGap {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]DataGap, len(s.gaps))
	copy(out, s.gaps)
	return out
}
func (s *collectingSink) snapshotRows() []FeedHealthRow {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]FeedHealthRow, len(s.rows))
	copy(out, s.rows)
	return out
}

type countingMetrics struct {
	mu       sync.Mutex
	gaps     int
	resets   int
}

func (m *countingMetrics) GapDetected()   { m.mu.Lock(); m.gaps++; m.mu.Unlock() }
func (m *countingMetrics) SequenceReset() { m.mu.Lock(); m.resets++; m.mu.Unlock() }

// ── gap detection over a synthetic sequence ─────────────────────────────────

func TestCheckSequenceDetectsGap(t *testing.T) {
	sink := &collectingSink{}
	metrics := &countingMetrics{}
	clk := clock.NewFake(time.Unix(0, 0))
	tr := NewTracker(Options{Clock: clk, Sink: sink, Metrics: metrics})
	ctx := context.Background()
	inst := uuid.New()

	// A synthetic sequence with a deliberate hole: 1,2,3,(4,5,6 missing),7,8.
	seqs := []int64{1, 2, 3, 7, 8}
	base := time.Unix(1000, 0).UTC()
	for i, seq := range seqs {
		tr.CheckSequence(ctx, inst, "sim", model.FeedTrades, seq, base.Add(time.Duration(i)*time.Second))
	}

	gaps := sink.snapshotGaps()
	if len(gaps) != 1 {
		t.Fatalf("expected exactly 1 gap recorded, got %d: %+v", len(gaps), gaps)
	}
	g := gaps[0]
	if g.ExpectedRows != 3 {
		t.Fatalf("expected 3 missing rows (seq 4,5,6), got %d", g.ExpectedRows)
	}
	if g.ActualRows != 0 {
		t.Fatalf("expected 0 actual rows for a pure gap, got %d", g.ActualRows)
	}
	if g.InstrumentID != inst || g.Feed != string(model.FeedTrades) {
		t.Fatalf("gap carries wrong instrument/feed: %+v", g)
	}
	if !g.GapEnd.After(g.GapStart) {
		t.Fatalf("gap_end must be after gap_start: %+v", g)
	}
	if metrics.gaps != 1 {
		t.Fatalf("expected GapDetected called once, got %d", metrics.gaps)
	}
}

func TestCheckSequenceNoGapForConsecutiveOrRepeatedSequence(t *testing.T) {
	sink := &collectingSink{}
	clk := clock.NewFake(time.Unix(0, 0))
	tr := NewTracker(Options{Clock: clk, Sink: sink})
	ctx := context.Background()
	inst := uuid.New()

	for i, seq := range []int64{1, 2, 3, 4, 5} {
		tr.CheckSequence(ctx, inst, "sim", model.FeedTrades, seq, time.Unix(int64(1000+i), 0))
	}
	if got := sink.snapshotGaps(); len(got) != 0 {
		t.Fatalf("expected no gaps for a consecutive sequence, got %d", len(got))
	}
}

func TestCheckSequenceBackwardsIsResetNotGap(t *testing.T) {
	sink := &collectingSink{}
	metrics := &countingMetrics{}
	clk := clock.NewFake(time.Unix(0, 0))
	tr := NewTracker(Options{Clock: clk, Sink: sink, Metrics: metrics})
	ctx := context.Background()
	inst := uuid.New()

	tr.CheckSequence(ctx, inst, "sim", model.FeedTrades, 100, time.Unix(1000, 0))
	// Vendor reconnected and restarted its counter.
	tr.CheckSequence(ctx, inst, "sim", model.FeedTrades, 1, time.Unix(1001, 0))

	if got := sink.snapshotGaps(); len(got) != 0 {
		t.Fatalf("a backwards sequence must be a reset, not a gap, got %d gaps", len(got))
	}
	if metrics.resets != 1 {
		t.Fatalf("expected 1 sequence reset counted, got %d", metrics.resets)
	}

	rows, err := tr.Report(ctx, time.Unix(1002, 0))
	if err != nil {
		t.Fatalf("Report: %v", err)
	}
	if len(rows) != 1 || rows[0].SequenceResets != 1 {
		t.Fatalf("expected the report to carry 1 sequence reset, got %+v", rows)
	}
}

// ── latency percentile computation ──────────────────────────────────────────

func TestLatencyPercentileComputation(t *testing.T) {
	sink := &collectingSink{}
	clk := clock.NewFake(time.Unix(0, 0))
	tr := NewTracker(Options{Clock: clk, Sink: sink})

	base := time.Unix(1000, 0).UTC()
	// 100 samples: latencies 1ms..100ms, exchange_ts=base, received=base+Nms.
	for i := 1; i <= 100; i++ {
		tr.RecordMessage("sim", model.FeedTrades, 128, base, base.Add(time.Duration(i)*time.Millisecond))
	}

	rows, err := tr.Report(context.Background(), base.Add(200*time.Millisecond))
	if err != nil {
		t.Fatalf("Report: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	row := rows[0]
	if row.Messages != 100 {
		t.Fatalf("expected 100 messages, got %d", row.Messages)
	}
	if row.Bytes != 12800 {
		t.Fatalf("expected 12800 bytes, got %d", row.Bytes)
	}
	if row.P50LatencyMs == nil || *row.P50LatencyMs != 50 {
		t.Fatalf("expected p50=50ms (nearest-rank over 1..100), got %v", row.P50LatencyMs)
	}
	if row.P99LatencyMs == nil || *row.P99LatencyMs != 99 {
		t.Fatalf("expected p99=99ms, got %v", row.P99LatencyMs)
	}
	if row.MaxLatencyMs == nil || *row.MaxLatencyMs != 100 {
		t.Fatalf("expected max=100ms, got %v", row.MaxLatencyMs)
	}
}

func TestReportWithNoMessagesLeavesLatenciesNil(t *testing.T) {
	sink := &collectingSink{}
	clk := clock.NewFake(time.Unix(0, 0))
	tr := NewTracker(Options{Clock: clk, Sink: sink})
	tr.RecordReconnect("polygon", model.FeedTrades)

	rows, err := tr.Report(context.Background(), time.Unix(1, 0))
	if err != nil {
		t.Fatalf("Report: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row (reconnect with no messages still reports), got %d", len(rows))
	}
	if rows[0].P50LatencyMs != nil || rows[0].P99LatencyMs != nil || rows[0].MaxLatencyMs != nil {
		t.Fatalf("expected nil latency fields when no messages were recorded, got %+v", rows[0])
	}
	if rows[0].Reconnects != 1 {
		t.Fatalf("expected 1 reconnect, got %d", rows[0].Reconnects)
	}
}

// ── Run reports on the clock ─────────────────────────────────────────────────

func TestRunReportsOnClock(t *testing.T) {
	sink := &collectingSink{}
	clk := clock.NewFake(time.Unix(0, 0))
	tr := NewTracker(Options{Interval: time.Second, Clock: clk, Sink: sink})
	tr.RecordMessage("sim", model.FeedTrades, 10, time.Unix(0, 0), time.Unix(0, 0))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- tr.Run(ctx) }()
	clk.BlockUntilPending(1)
	clk.Advance(2 * time.Second)

	deadline := time.After(2 * time.Second)
	for {
		if len(sink.snapshotRows()) > 0 {
			break
		}
		select {
		case <-deadline:
			t.Fatal("timed out waiting for a clock-driven report")
		default:
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not shut down after cancel")
	}
}
