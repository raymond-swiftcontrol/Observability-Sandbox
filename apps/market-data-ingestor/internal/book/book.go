// Package book maintains per-instrument L2 order books from a vendor
// snapshot plus its subsequent incremental updates, mirroring
// market.book_snapshot in db/migrations/0004.
//
// Sequencing is the whole game here. A book built from an out-of-order or
// gapped increment stream is worse than no book at all — it looks plausible
// and is wrong, and imbalance features computed on it silently poison
// anything downstream. So the manager validates every increment's sequence
// against the book it is being applied to and, on any discontinuity, throws
// the book away and asks for a fresh snapshot rather than guessing.
package book

import (
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
	"github.com/shopspring/decimal"
)

// State is the manager's view of one instrument's book health.
type State int

// Book states.
const (
	// StateUnseeded has never received a snapshot; every increment is
	// rejected until one arrives.
	StateUnseeded State = iota
	// StateLive has a consistent, sequence-validated book.
	StateLive
	// StateNeedsResync detected a gap or a crossed book and discarded its
	// state; it stays here, rejecting increments, until the next snapshot.
	StateNeedsResync
)

func (s State) String() string {
	switch s {
	case StateUnseeded:
		return "unseeded"
	case StateLive:
		return "live"
	case StateNeedsResync:
		return "needs_resync"
	}
	return "unknown"
}

// ── the price ladder ─────────────────────────────────────────────────────────
//
// A book side is kept as a slice of levels sorted by price (bids descending,
// asks ascending) with binary search for the insert/update/delete point. That
// gives O(log n) to locate a level and O(n) to shift the slice on insert or
// delete — for a top-of-book-weighted workload (depth in the tens of levels,
// the overwhelming majority of updates touching the first few) the shift cost
// is dwarfed by the win of a compact, cache-friendly, allocation-free scan
// for the L1/L5 imbalance computation, which runs on every single update. A
// balanced tree (or a heap) gives the same O(log n) update but forces a
// pointer-chasing walk to materialise "the best 5 levels", which is the read
// path that matters most; a flat sorted slice makes that walk the first 5
// elements of an array. At the depths this service configures (MD_BOOK_DEPTH,
// default 10, capped at 1000 by config validation) the shift is never more
// than ~1000 decimal.Decimal moves, which is microseconds — nowhere near the
// cost of the network hop that delivered the update.
type side struct {
	levels []model.BookLevel
	desc   bool // true for bids (descending), false for asks (ascending)
}

func newSide(desc bool) *side { return &side{desc: desc} }

// less reports whether price a sorts before price b for this side's order.
func (s *side) less(a, b decimal.Decimal) bool {
	if s.desc {
		return a.GreaterThan(b)
	}
	return a.LessThan(b)
}

// find returns the index of price, and whether it was found. When not found,
// the index is where it should be inserted to keep the slice sorted.
func (s *side) find(price decimal.Decimal) (int, bool) {
	i := sort.Search(len(s.levels), func(i int) bool {
		return !s.less(s.levels[i].Price, price)
	})
	if i < len(s.levels) && s.levels[i].Price.Equal(price) {
		return i, true
	}
	return i, false
}

// upsert sets a level's size, inserting it in sorted position if new. A
// zero-or-negative size deletes the level, matching the convention documented
// on model.BookDelta.
func (s *side) upsert(lvl model.BookLevel) {
	i, found := s.find(lvl.Price)
	if !lvl.Size.IsPositive() {
		if found {
			s.levels = append(s.levels[:i], s.levels[i+1:]...)
		}
		return
	}
	if found {
		s.levels[i] = lvl
		return
	}
	s.levels = append(s.levels, model.BookLevel{})
	copy(s.levels[i+1:], s.levels[i:])
	s.levels[i] = lvl
}

// replace wholesale-replaces the side's levels with a freshly sorted copy of
// lvls, used when applying a snapshot.
func (s *side) replace(lvls []model.BookLevel) {
	cp := append([]model.BookLevel(nil), lvls...)
	sort.Slice(cp, func(i, j int) bool { return s.less(cp[i].Price, cp[j].Price) })
	s.levels = cp
}

func (s *side) best() (model.BookLevel, bool) {
	if len(s.levels) == 0 {
		return model.BookLevel{}, false
	}
	return s.levels[0], true
}

func (s *side) top(n int) []model.BookLevel {
	if n > len(s.levels) {
		n = len(s.levels)
	}
	out := make([]model.BookLevel, n)
	copy(out, s.levels[:n])
	return out
}

// ── one instrument's book ────────────────────────────────────────────────────

// Book is one instrument's L2 book.
type Book struct {
	InstrumentID uuid.UUID
	Symbol       string
	State        State
	Sequence     int64
	UpdatedAt    time.Time
	Resyncs      int64

	bids *side
	asks *side
}

func newBook(instrumentID uuid.UUID, symbol string) *Book {
	return &Book{
		InstrumentID: instrumentID,
		Symbol:       symbol,
		State:        StateUnseeded,
		bids:         newSide(true),
		asks:         newSide(false),
	}
}

// crossed reports whether the best bid is at or above the best ask.
func (b *Book) crossed() bool {
	bid, hasBid := b.bids.best()
	ask, hasAsk := b.asks.best()
	if !hasBid || !hasAsk {
		return false
	}
	return bid.Price.GreaterThanOrEqual(ask.Price)
}

// ApplySnapshot replaces the whole book. A snapshot is always accepted — it
// is, by definition, self-consistent — and always moves the book to Live
// unless it is internally crossed, which is rejected outright rather than
// seeded, because a crossed snapshot means the vendor's own view is broken.
func (b *Book) ApplySnapshot(snap model.BookSnapshot) error {
	bids := newSide(true)
	bids.replace(snap.Bids)
	asks := newSide(false)
	asks.replace(snap.Asks)

	if bb, hasBid := bids.best(); hasBid {
		if ba, hasAsk := asks.best(); hasAsk && bb.Price.GreaterThanOrEqual(ba.Price) {
			return fmt.Errorf("%w: snapshot best bid %s >= best ask %s", ErrCrossedBook, bb.Price, ba.Price)
		}
	}

	b.bids = bids
	b.asks = asks
	b.Sequence = snap.Sequence
	b.UpdatedAt = snap.TS
	b.State = StateLive
	return nil
}

// ErrCrossedBook marks an update that would leave, or already leaves, the
// book crossed. It is rejected rather than applied so a bad increment cannot
// corrupt every imbalance computation downstream of it.
var ErrCrossedBook = errors.New("book: crossed book")

// ErrGap marks a detected sequence discontinuity. The caller (Manager) reacts
// to it by forcing StateNeedsResync; it is exported so callers can
// distinguish "gap, please resnapshot" from other apply failures.
var ErrGap = errors.New("book: sequence gap detected")

// ApplyDelta applies one incremental update. It fails closed: any of
// "book not yet seeded", "sequence gap", or "would cross the book" leaves the
// book unmodified and returns an error; the caller is expected to move the
// book to StateNeedsResync on ErrGap (Manager does this).
func (b *Book) ApplyDelta(d model.BookDelta) error {
	if b.State != StateLive {
		return fmt.Errorf("book: cannot apply delta while %s", b.State)
	}
	// PrevSequence <= 0 means the vendor did not supply a base sequence
	// (SimVendor/Polygon-style single-counter deltas); those are validated
	// purely by strict increase instead.
	if d.PrevSequence > 0 {
		if d.PrevSequence != b.Sequence {
			return fmt.Errorf("%w: instrument=%s expected prev_sequence=%d got=%d",
				ErrGap, b.InstrumentID, b.Sequence, d.PrevSequence)
		}
	} else if d.Sequence <= b.Sequence {
		return fmt.Errorf("%w: instrument=%s sequence %d did not advance past %d",
			ErrGap, b.InstrumentID, d.Sequence, b.Sequence)
	}

	// Apply to scratch copies first so a crossed result can be rejected
	// without leaving the live book half-mutated.
	bids := &side{desc: true, levels: append([]model.BookLevel(nil), b.bids.levels...)}
	asks := &side{desc: false, levels: append([]model.BookLevel(nil), b.asks.levels...)}
	for _, lvl := range d.Bids {
		bids.upsert(lvl)
	}
	for _, lvl := range d.Asks {
		asks.upsert(lvl)
	}
	if bb, hasBid := bids.best(); hasBid {
		if ba, hasAsk := asks.best(); hasAsk && bb.Price.GreaterThanOrEqual(ba.Price) {
			return fmt.Errorf("%w: applying delta would cross bid %s / ask %s", ErrCrossedBook, bb.Price, ba.Price)
		}
	}

	b.bids = bids
	b.asks = asks
	b.Sequence = d.Sequence
	b.UpdatedAt = d.TS
	return nil
}

// Snapshot renders the current book (up to depth levels per side) as the
// model type persisted to market.book_snapshot, including the L1/L5
// imbalance columns.
func (b *Book) Snapshot(depth int) model.BookSnapshot {
	bids := b.bids.top(depth)
	asks := b.asks.top(depth)
	return model.BookSnapshot{
		TS:           b.UpdatedAt,
		InstrumentID: b.InstrumentID,
		Symbol:       b.Symbol,
		Sequence:     b.Sequence,
		Bids:         bids,
		Asks:         asks,
		DepthLevels:  int16(max(len(bids), len(asks))),
		ImbalanceL1:  Imbalance(b.bids.top(1), b.asks.top(1)),
		ImbalanceL5:  Imbalance(b.bids.top(5), b.asks.top(5)),
	}
}

// Imbalance computes (Σbid_size - Σask_size) / (Σbid_size + Σask_size) over
// the supplied levels, matching market.book_snapshot.imbalance_l1/l5: +1 means
// entirely bid-side depth, -1 entirely ask-side, 0 perfectly balanced or both
// sides empty.
func Imbalance(bids, asks []model.BookLevel) decimal.Decimal {
	bidSz := sumSize(bids)
	askSz := sumSize(asks)
	total := bidSz.Add(askSz)
	if total.IsZero() {
		return decimal.Zero
	}
	return bidSz.Sub(askSz).Div(total)
}

func sumSize(lvls []model.BookLevel) decimal.Decimal {
	sum := decimal.Zero
	for _, l := range lvls {
		sum = sum.Add(l.Size)
	}
	return sum
}
