package book

import (
	"context"
	"errors"
	"log/slog"
	"sync"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
)

// Metrics receives the manager's counters.
type Metrics interface {
	Resync(reason string)
}

type nopMetrics struct{}

func (nopMetrics) Resync(string) {}

// Snapshotter requests a fresh snapshot for an instrument from the vendor. A
// gap must trigger an explicit re-subscribe/re-snapshot round trip, never a
// local patch-over — see the package doc for why.
type Snapshotter interface {
	RequestSnapshot(ctx context.Context, instrumentID uuid.UUID, symbol string) error
}

// Sink receives rendered snapshots (both real vendor snapshots, once applied,
// and periodic republishes of the live book) for downstream publication.
type Sink interface {
	EmitBookSnapshot(ctx context.Context, snap model.BookSnapshot) error
}

// Manager owns one Book per instrument and is the single entry point the
// ingestion pipeline calls with vendor book events.
type Manager struct {
	depth       int
	snapshotter Snapshotter
	sink        Sink
	metrics     Metrics
	logger      *slog.Logger

	mu    sync.Mutex
	books map[uuid.UUID]*Book
}

// Options configures a Manager.
type Options struct {
	// Depth is how many levels per side Snapshot renders and Sink receives.
	Depth       int
	Snapshotter Snapshotter
	Sink        Sink
	Metrics     Metrics
	Logger      *slog.Logger
}

// NewManager builds a Manager.
func NewManager(opts Options) *Manager {
	if opts.Depth <= 0 {
		opts.Depth = 10
	}
	if opts.Metrics == nil {
		opts.Metrics = nopMetrics{}
	}
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	return &Manager{
		depth:       opts.Depth,
		snapshotter: opts.Snapshotter,
		sink:        opts.Sink,
		metrics:     opts.Metrics,
		logger:      opts.Logger,
		books:       map[uuid.UUID]*Book{},
	}
}

func (m *Manager) bookFor(instrumentID uuid.UUID, symbol string) *Book {
	b, ok := m.books[instrumentID]
	if !ok {
		b = newBook(instrumentID, symbol)
		m.books[instrumentID] = b
	}
	return b
}

// Get returns a snapshot of one instrument's book state for read paths
// (gRPC, diagnostics). ok is false when the instrument has never been seen.
func (m *Manager) Get(instrumentID uuid.UUID) (model.BookSnapshot, State, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	b, ok := m.books[instrumentID]
	if !ok {
		return model.BookSnapshot{}, StateUnseeded, false
	}
	return b.Snapshot(m.depth), b.State, true
}

// ApplyEvent is the single ingestion entry point: a BookDelta with
// Snapshot=true is treated as a full snapshot, everything else as an
// increment. It never returns an error for a data-quality problem (gap,
// crossed book): those are handled internally by forcing a resync and are
// only observable through the metric and the log line, because one bad
// vendor frame must not stop the pipeline that carries every other symbol.
func (m *Manager) ApplyEvent(ctx context.Context, d model.BookDelta) {
	if d.Snapshot {
		m.applySnapshotDelta(ctx, d)
		return
	}
	m.applyIncrement(ctx, d)
}

// ApplySnapshot applies a full snapshot fetched out of band (e.g. a REST
// response to a Snapshotter.RequestSnapshot call), completing a resync.
func (m *Manager) ApplySnapshot(ctx context.Context, snap model.BookSnapshot) {
	m.mu.Lock()
	b := m.bookFor(snap.InstrumentID, snap.Symbol)
	err := b.ApplySnapshot(snap)
	var out model.BookSnapshot
	if err == nil {
		out = b.Snapshot(m.depth)
	}
	m.mu.Unlock()

	if err != nil {
		m.logger.ErrorContext(ctx, "rejected crossed snapshot", slog.String("instrument_id", snap.InstrumentID.String()), slog.Any("error", err))
		return
	}
	m.publish(ctx, out)
}

func (m *Manager) applySnapshotDelta(ctx context.Context, d model.BookDelta) {
	snap := model.BookSnapshot{
		TS: d.TS, InstrumentID: d.InstrumentID, Symbol: d.Symbol,
		Sequence: d.Sequence, Bids: d.Bids, Asks: d.Asks,
	}
	m.ApplySnapshot(ctx, snap)
}

func (m *Manager) applyIncrement(ctx context.Context, d model.BookDelta) {
	m.mu.Lock()
	b := m.bookFor(d.InstrumentID, d.Symbol)
	if b.State != StateLive {
		// Already known to be broken (or never seeded): every increment is a
		// no-op until the pending resnapshot lands, rather than queuing or
		// guessing at an ordering we cannot verify.
		m.mu.Unlock()
		m.requestResync(ctx, d.InstrumentID, d.Symbol, "not_live")
		return
	}
	err := b.ApplyDelta(d)
	var out model.BookSnapshot
	if err == nil {
		out = b.Snapshot(m.depth)
	} else if errors.Is(err, ErrGap) || errors.Is(err, ErrCrossedBook) {
		b.State = StateNeedsResync
		b.Resyncs++
	}
	m.mu.Unlock()

	if err != nil {
		reason := "apply_error"
		switch {
		case errors.Is(err, ErrGap):
			reason = "sequence_gap"
		case errors.Is(err, ErrCrossedBook):
			reason = "crossed_book"
		}
		m.logger.WarnContext(ctx, "book increment rejected, forcing resync",
			slog.String("instrument_id", d.InstrumentID.String()), slog.String("reason", reason), slog.Any("error", err))
		m.requestResync(ctx, d.InstrumentID, d.Symbol, reason)
		return
	}
	m.publish(ctx, out)
}

func (m *Manager) requestResync(ctx context.Context, instrumentID uuid.UUID, symbol, reason string) {
	m.metrics.Resync(reason)
	if m.snapshotter == nil {
		return
	}
	if err := m.snapshotter.RequestSnapshot(ctx, instrumentID, symbol); err != nil {
		m.logger.ErrorContext(ctx, "failed to request book resync snapshot",
			slog.String("instrument_id", instrumentID.String()), slog.Any("error", err))
	}
}

func (m *Manager) publish(ctx context.Context, snap model.BookSnapshot) {
	if m.sink == nil {
		return
	}
	if err := m.sink.EmitBookSnapshot(ctx, snap); err != nil {
		m.logger.ErrorContext(ctx, "failed to publish book snapshot",
			slog.String("instrument_id", snap.InstrumentID.String()), slog.Any("error", err))
	}
}
