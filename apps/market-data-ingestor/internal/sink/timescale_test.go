package sink

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/clock"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
	"github.com/shopspring/decimal"
)

// fakePool records every CopyFrom call's rows (by draining the CopyFromSource)
// and can be told to fail the next N attempts, to exercise the retry/shed path
// without a real Postgres.
type fakePool struct {
	mu       sync.Mutex
	rowsSeen [][][]any
	failNext int
	pingErr  error
}

func (f *fakePool) CopyFrom(ctx context.Context, table pgx.Identifier, columns []string, src pgx.CopyFromSource) (int64, error) {
	var rows [][]any
	for src.Next() {
		v, err := src.Values()
		if err != nil {
			return 0, err
		}
		rows = append(rows, v)
	}
	if err := src.Err(); err != nil {
		return 0, err
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failNext > 0 {
		f.failNext--
		return 0, errors.New("fake: simulated database outage")
	}
	f.rowsSeen = append(f.rowsSeen, rows)
	return int64(len(rows)), nil
}

func (f *fakePool) Ping(context.Context) error { return f.pingErr }

func (f *fakePool) totalRows() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, b := range f.rowsSeen {
		n += len(b)
	}
	return n
}

func (f *fakePool) batchSizes() []int {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]int, len(f.rowsSeen))
	for i, b := range f.rowsSeen {
		out[i] = len(b)
	}
	return out
}

func sampleTrade(price string) model.Trade {
	return model.Trade{
		TS: time.Unix(1000, 0).UTC(), InstrumentID: uuid.New(), Symbol: "AAPL",
		Price: decimal.RequireFromString(price), Size: decimal.RequireFromString("10"),
		Quality: model.QualityVendor,
	}
}

// ── batching triggers on size ────────────────────────────────────────────────

func TestTableWriterFlushTriggersOnSize(t *testing.T) {
	pool := &fakePool{}
	clk := clock.NewFake(time.Unix(0, 0))
	w := NewTradeWriter(pool, BatchConfig{BatchRows: 5, BatchInterval: time.Hour, BufferRows: 1000}, clk, nil, nil)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = w.Run(ctx) }()
	clk.BlockUntilPending(1) // Run's ticker is registered

	for i := 0; i < 5; i++ {
		w.Add(sampleTrade("100.00"))
	}

	deadline := time.After(2 * time.Second)
	for {
		if pool.totalRows() == 5 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("timed out waiting for a size-triggered flush; got %d rows", pool.totalRows())
		default:
		}
	}
}

// ── batching triggers on time ────────────────────────────────────────────────

func TestTableWriterFlushTriggersOnTime(t *testing.T) {
	pool := &fakePool{}
	clk := clock.NewFake(time.Unix(0, 0))
	w := NewTradeWriter(pool, BatchConfig{BatchRows: 10000, BatchInterval: time.Second, BufferRows: 1000}, clk, nil, nil)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = w.Run(ctx) }()
	clk.BlockUntilPending(1)

	// Only 2 rows, nowhere near BatchRows — only the time trigger can flush.
	w.Add(sampleTrade("1"))
	w.Add(sampleTrade("2"))
	clk.Advance(2 * time.Second)

	deadline := time.After(2 * time.Second)
	for {
		if pool.totalRows() == 2 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("timed out waiting for a time-triggered flush; got %d rows", pool.totalRows())
		default:
		}
	}
}

// ── shed path increments its metric ─────────────────────────────────────────

func TestTableWriterShedsPastBufferBound(t *testing.T) {
	pool := &fakePool{failNext: 1000000} // every CopyFrom fails: simulate an outage
	metrics := newFakeSinkMetrics()
	clk := clock.NewFake(time.Unix(0, 0))
	w := NewTradeWriter(pool, BatchConfig{BatchRows: 3, BatchInterval: time.Hour, BufferRows: 5}, clk, metrics, nil)
	ctx := context.Background()

	for i := 0; i < 5; i++ {
		w.Add(sampleTrade("1"))
	}
	if got := w.Pending(); got != 5 {
		t.Fatalf("expected 5 buffered rows before hitting the bound, got %d", got)
	}
	// The buffer is now at BufferRows; further rows must be shed, not queued.
	w.Add(sampleTrade("2"))
	w.Add(sampleTrade("3"))
	if got := w.Pending(); got != 5 {
		t.Fatalf("shed rows must not grow the buffer past the bound, got %d", got)
	}
	metrics.mu.Lock()
	shed := metrics.shed
	metrics.mu.Unlock()
	if shed != 2 {
		t.Fatalf("expected 2 shed rows counted, got %d", shed)
	}

	// A flush attempt against the failing pool must not lose the buffered
	// rows: they stay queued for retry.
	if err := w.Flush(ctx); err == nil {
		t.Fatalf("expected Flush to report the simulated outage")
	}
	if got := w.Pending(); got != 5 {
		t.Fatalf("a failed flush must retain its rows for retry, got %d pending", got)
	}
}

func TestTableWriterRecoversAfterOutage(t *testing.T) {
	pool := &fakePool{failNext: 1}
	clk := clock.NewFake(time.Unix(0, 0))
	w := NewTradeWriter(pool, BatchConfig{BatchRows: 100, BatchInterval: time.Hour, BufferRows: 1000}, clk, nil, nil)
	ctx := context.Background()

	w.Add(sampleTrade("1"))
	w.Add(sampleTrade("2"))
	if err := w.Flush(ctx); err == nil {
		t.Fatalf("expected the first flush to fail (simulated outage)")
	}
	if got := w.Pending(); got != 2 {
		t.Fatalf("expected both rows retained after the failed flush, got %d", got)
	}
	if err := w.Flush(ctx); err != nil {
		t.Fatalf("expected the retry to succeed, got %v", err)
	}
	if got := w.Pending(); got != 0 {
		t.Fatalf("expected the buffer drained after a successful retry, got %d", got)
	}
	if got := pool.totalRows(); got != 2 {
		t.Fatalf("expected both rows eventually written, got %d", got)
	}
}

// ── book_snapshot jsonb columns round-trip through the row projector ───────

func TestBookSnapshotWriterProjectsJSONLevels(t *testing.T) {
	pool := &fakePool{}
	clk := clock.NewFake(time.Unix(0, 0))
	w := NewBookSnapshotWriter(pool, BatchConfig{BatchRows: 1, BatchInterval: time.Hour, BufferRows: 10}, clk, nil, nil)
	ctx := context.Background()

	snap := model.BookSnapshot{
		TS: time.Unix(1, 0).UTC(), InstrumentID: uuid.New(), Symbol: "AAPL", Sequence: 5,
		Bids:        []model.BookLevel{{Price: decimal.RequireFromString("99.00"), Size: decimal.RequireFromString("10")}},
		Asks:        []model.BookLevel{{Price: decimal.RequireFromString("100.00"), Size: decimal.RequireFromString("5")}},
		DepthLevels: 1, ImbalanceL1: decimal.RequireFromString("0.33"),
	}
	w.Add(snap)
	if err := w.Flush(ctx); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	if got := pool.totalRows(); got != 1 {
		t.Fatalf("expected 1 row written, got %d", got)
	}
	row := pool.rowsSeen[0][0]
	// columns: ts, instrument_id, sequence, bids, asks, depth_levels, imbalance_l1, imbalance_l5
	bidsJSON, ok := row[3].(json.RawMessage)
	if !ok {
		t.Fatalf("expected column 3 (bids) to be json.RawMessage, got %T", row[3])
	}
	var decoded []model.BookLevel
	if err := json.Unmarshal(bidsJSON, &decoded); err != nil {
		t.Fatalf("bids column did not decode as a JSON array of levels: %v", err)
	}
	if len(decoded) != 1 || !decoded[0].Price.Equal(decimal.RequireFromString("99.00")) {
		t.Fatalf("unexpected decoded bids: %+v", decoded)
	}
}
