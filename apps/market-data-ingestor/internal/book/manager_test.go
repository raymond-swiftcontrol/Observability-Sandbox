package book

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
)

type fakeSnapshotter struct {
	mu       sync.Mutex
	requests []uuid.UUID
}

func (f *fakeSnapshotter) RequestSnapshot(_ context.Context, instrumentID uuid.UUID, _ string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests = append(f.requests, instrumentID)
	return nil
}

func (f *fakeSnapshotter) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

type fakeSink struct {
	mu    sync.Mutex
	snaps []model.BookSnapshot
}

func (f *fakeSink) EmitBookSnapshot(_ context.Context, snap model.BookSnapshot) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.snaps = append(f.snaps, snap)
	return nil
}

func (f *fakeSink) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.snaps)
}

type fakeMetrics struct {
	mu      sync.Mutex
	resyncs map[string]int
}

func newFakeMetrics() *fakeMetrics { return &fakeMetrics{resyncs: map[string]int{}} }
func (f *fakeMetrics) Resync(reason string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.resyncs[reason]++
}
func (f *fakeMetrics) get(reason string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.resyncs[reason]
}

func TestManagerGapTriggersResyncRequest(t *testing.T) {
	inst := uuid.New()
	snapper := &fakeSnapshotter{}
	sink := &fakeSink{}
	metrics := newFakeMetrics()
	m := NewManager(Options{Depth: 5, Snapshotter: snapper, Sink: sink, Metrics: metrics})
	ctx := context.Background()

	m.ApplySnapshot(ctx, baseSnapshot(inst, 100))
	if sink.count() != 1 {
		t.Fatalf("expected the snapshot to publish, got %d", sink.count())
	}

	gap := model.BookDelta{
		TS: time.Unix(1002, 0).UTC(), InstrumentID: inst, Symbol: "AAPL",
		Sequence: 200, PrevSequence: 199, // book is at 100; this skips a huge range
		Bids: []model.BookLevel{lvl("99.00", "10")},
	}
	m.ApplyEvent(ctx, gap)

	if got := snapper.count(); got != 1 {
		t.Fatalf("expected exactly 1 resync request after the gap, got %d", got)
	}
	if got := metrics.get("sequence_gap"); got != 1 {
		t.Fatalf("expected sequence_gap resync metric = 1, got %d", got)
	}
	_, state, ok := m.Get(inst)
	if !ok || state != StateNeedsResync {
		t.Fatalf("expected book state to be NeedsResync after a gap, got %s (ok=%v)", state, ok)
	}

	// Further increments must not be applied while awaiting resync; each one
	// requests another resync rather than guessing.
	another := model.BookDelta{
		TS: time.Unix(1003, 0).UTC(), InstrumentID: inst, Symbol: "AAPL",
		Sequence: 201, PrevSequence: 200,
		Bids: []model.BookLevel{lvl("50.00", "1")},
	}
	m.ApplyEvent(ctx, another)
	if got := snapper.count(); got != 2 {
		t.Fatalf("expected a second resync request while not_live, got %d", got)
	}
	snap, _, _ := m.Get(inst)
	if snap.Bids[0].Price.Equal(d("50.00")) {
		t.Fatalf("an increment must not be applied while the book needs resync")
	}

	// The resync completes with a fresh snapshot.
	m.ApplySnapshot(ctx, baseSnapshot(inst, 300))
	_, state, _ = m.Get(inst)
	if state != StateLive {
		t.Fatalf("expected StateLive after the resync snapshot, got %s", state)
	}
}

func TestManagerCrossedSnapshotDoesNotSeed(t *testing.T) {
	inst := uuid.New()
	m := NewManager(Options{})
	ctx := context.Background()

	crossed := model.BookSnapshot{
		InstrumentID: inst, Symbol: "AAPL", Sequence: 1,
		Bids: []model.BookLevel{lvl("100.00", "1")},
		Asks: []model.BookLevel{lvl("99.00", "1")},
	}
	m.ApplySnapshot(ctx, crossed)
	_, state, ok := m.Get(inst)
	if !ok || state == StateLive {
		t.Fatalf("a crossed snapshot must not leave the book live, got state=%s ok=%v", state, ok)
	}
}
