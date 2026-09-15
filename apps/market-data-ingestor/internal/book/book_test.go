package book

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
	"github.com/shopspring/decimal"
)

func d(s string) decimal.Decimal { return decimal.RequireFromString(s) }

func lvl(price, size string) model.BookLevel {
	return model.BookLevel{Price: d(price), Size: d(size)}
}

func baseSnapshot(inst uuid.UUID, seq int64) model.BookSnapshot {
	return model.BookSnapshot{
		TS: time.Unix(1000, 0).UTC(), InstrumentID: inst, Symbol: "AAPL", Sequence: seq,
		Bids: []model.BookLevel{lvl("99.00", "100"), lvl("98.50", "200"), lvl("98.00", "300")},
		Asks: []model.BookLevel{lvl("99.50", "150"), lvl("100.00", "250"), lvl("100.50", "350")},
	}
}

// ── snapshot then increments ─────────────────────────────────────────────────

func TestApplySnapshotThenIncrements(t *testing.T) {
	inst := uuid.New()
	b := newBook(inst, "AAPL")

	if err := b.ApplySnapshot(baseSnapshot(inst, 100)); err != nil {
		t.Fatalf("ApplySnapshot: %v", err)
	}
	if b.State != StateLive {
		t.Fatalf("expected StateLive after snapshot, got %s", b.State)
	}

	// Improve the best bid and add a new best ask level.
	delta := model.BookDelta{
		TS: time.Unix(1001, 0).UTC(), InstrumentID: inst, Symbol: "AAPL",
		Sequence: 101, PrevSequence: 100,
		Bids: []model.BookLevel{lvl("99.25", "50")},
		Asks: []model.BookLevel{lvl("99.40", "75")},
	}
	if err := b.ApplyDelta(delta); err != nil {
		t.Fatalf("ApplyDelta: %v", err)
	}

	snap := b.Snapshot(10)
	if len(snap.Bids) == 0 || !snap.Bids[0].Price.Equal(d("99.25")) {
		t.Fatalf("expected best bid 99.25 after increment, got %+v", snap.Bids)
	}
	if len(snap.Asks) == 0 || !snap.Asks[0].Price.Equal(d("99.40")) {
		t.Fatalf("expected best ask 99.40 after increment, got %+v", snap.Asks)
	}
	if snap.Sequence != 101 {
		t.Fatalf("expected sequence 101, got %d", snap.Sequence)
	}
}

// ── gap detection triggers a required resync, not a silent patch ───────────

func TestApplyDeltaGapDetected(t *testing.T) {
	inst := uuid.New()
	b := newBook(inst, "AAPL")
	if err := b.ApplySnapshot(baseSnapshot(inst, 100)); err != nil {
		t.Fatalf("ApplySnapshot: %v", err)
	}

	// PrevSequence should be 100 (the current book sequence); 105 means we
	// missed everything in between.
	gapDelta := model.BookDelta{
		TS: time.Unix(1002, 0).UTC(), InstrumentID: inst, Symbol: "AAPL",
		Sequence: 106, PrevSequence: 105,
		Bids: []model.BookLevel{lvl("99.00", "10")},
	}
	err := b.ApplyDelta(gapDelta)
	if !errors.Is(err, ErrGap) {
		t.Fatalf("expected ErrGap, got %v", err)
	}

	// The book must be left exactly as it was: the caller (Manager), not the
	// Book itself, transitions state on a gap, and the levels must not have
	// been mutated by the rejected delta.
	snap := b.Snapshot(10)
	if !snap.Bids[0].Price.Equal(d("99.00")) || !snap.Bids[0].Size.Equal(d("100")) {
		t.Fatalf("book was mutated by a rejected gapped delta: %+v", snap.Bids[0])
	}
	if b.Sequence != 100 {
		t.Fatalf("sequence must not advance on a rejected delta, got %d", b.Sequence)
	}
}

func TestApplyDeltaNonIncreasingSequenceIsGap(t *testing.T) {
	inst := uuid.New()
	b := newBook(inst, "AAPL")
	if err := b.ApplySnapshot(baseSnapshot(inst, 100)); err != nil {
		t.Fatalf("ApplySnapshot: %v", err)
	}
	// No PrevSequence supplied (vendor style like Binance bookTicker/Polygon):
	// sequence must still strictly increase.
	stale := model.BookDelta{
		TS: time.Unix(1002, 0).UTC(), InstrumentID: inst, Symbol: "AAPL",
		Sequence: 100, Bids: []model.BookLevel{lvl("99.00", "10")},
	}
	if err := b.ApplyDelta(stale); !errors.Is(err, ErrGap) {
		t.Fatalf("expected ErrGap for a non-increasing sequence, got %v", err)
	}
}

// ── crossed-book rejection ───────────────────────────────────────────────────

func TestApplySnapshotRejectsCrossedBook(t *testing.T) {
	inst := uuid.New()
	b := newBook(inst, "AAPL")
	crossed := model.BookSnapshot{
		TS: time.Unix(1000, 0).UTC(), InstrumentID: inst, Symbol: "AAPL", Sequence: 1,
		Bids: []model.BookLevel{lvl("100.00", "10")},
		Asks: []model.BookLevel{lvl("99.00", "10")}, // ask below bid: crossed
	}
	if err := b.ApplySnapshot(crossed); !errors.Is(err, ErrCrossedBook) {
		t.Fatalf("expected ErrCrossedBook, got %v", err)
	}
	if b.State == StateLive {
		t.Fatalf("a rejected crossed snapshot must not seed the book")
	}
}

func TestApplyDeltaRejectsResultingCrossedBook(t *testing.T) {
	inst := uuid.New()
	b := newBook(inst, "AAPL")
	if err := b.ApplySnapshot(baseSnapshot(inst, 100)); err != nil {
		t.Fatalf("ApplySnapshot: %v", err)
	}
	// Best ask is 99.50; push a bid above it.
	crossing := model.BookDelta{
		TS: time.Unix(1001, 0).UTC(), InstrumentID: inst, Symbol: "AAPL",
		Sequence: 101, PrevSequence: 100,
		Bids: []model.BookLevel{lvl("99.75", "10")},
	}
	if err := b.ApplyDelta(crossing); !errors.Is(err, ErrCrossedBook) {
		t.Fatalf("expected ErrCrossedBook, got %v", err)
	}
	// Unmutated: best bid is still the original 99.00.
	snap := b.Snapshot(10)
	if !snap.Bids[0].Price.Equal(d("99.00")) {
		t.Fatalf("book must not be mutated by a rejected crossing delta, best bid = %s", snap.Bids[0].Price)
	}
}

// ── deletion of a price level ────────────────────────────────────────────────

func TestDeleteLevel(t *testing.T) {
	inst := uuid.New()
	b := newBook(inst, "AAPL")
	if err := b.ApplySnapshot(baseSnapshot(inst, 100)); err != nil {
		t.Fatalf("ApplySnapshot: %v", err)
	}
	// Zero size on an existing level removes it, per the model.BookDelta
	// convention.
	del := model.BookDelta{
		TS: time.Unix(1001, 0).UTC(), InstrumentID: inst, Symbol: "AAPL",
		Sequence: 101, PrevSequence: 100,
		Bids: []model.BookLevel{lvl("98.50", "0")},
	}
	if err := b.ApplyDelta(del); err != nil {
		t.Fatalf("ApplyDelta: %v", err)
	}
	snap := b.Snapshot(10)
	for _, l := range snap.Bids {
		if l.Price.Equal(d("98.50")) {
			t.Fatalf("level 98.50 should have been deleted, still present: %+v", snap.Bids)
		}
	}
	if len(snap.Bids) != 2 {
		t.Fatalf("expected 2 remaining bid levels, got %d: %+v", len(snap.Bids), snap.Bids)
	}
}

// ── imbalance math, hand-traced ──────────────────────────────────────────────

func TestImbalanceL1AndL5HandTraced(t *testing.T) {
	inst := uuid.New()
	b := newBook(inst, "AAPL")
	snap := model.BookSnapshot{
		TS: time.Unix(1000, 0).UTC(), InstrumentID: inst, Symbol: "AAPL", Sequence: 1,
		Bids: []model.BookLevel{
			lvl("100.00", "100"), // L1
			lvl("99.90", "50"),
			lvl("99.80", "50"),
			lvl("99.70", "50"),
			lvl("99.60", "50"), // top 5 bid sum = 300
		},
		Asks: []model.BookLevel{
			lvl("100.10", "50"), // L1
			lvl("100.20", "50"),
			lvl("100.30", "50"),
			lvl("100.40", "50"),
			lvl("100.50", "50"), // top 5 ask sum = 250
		},
	}
	if err := b.ApplySnapshot(snap); err != nil {
		t.Fatalf("ApplySnapshot: %v", err)
	}
	out := b.Snapshot(5)

	// L1: (100 - 50) / (100 + 50) = 50/150 = 1/3
	wantL1 := d("50").Div(d("150"))
	if !out.ImbalanceL1.Equal(wantL1) {
		t.Fatalf("ImbalanceL1 = %s, want %s", out.ImbalanceL1, wantL1)
	}
	// L5: (300 - 250) / (300 + 250) = 50/550
	wantL5 := d("50").Div(d("550"))
	if !out.ImbalanceL5.Equal(wantL5) {
		t.Fatalf("ImbalanceL5 = %s, want %s", out.ImbalanceL5, wantL5)
	}
}

func TestImbalanceEmptySideIsZeroNotDivByZero(t *testing.T) {
	got := Imbalance(nil, nil)
	if !got.Equal(decimal.Zero) {
		t.Fatalf("expected 0 for two empty sides, got %s", got)
	}
}
