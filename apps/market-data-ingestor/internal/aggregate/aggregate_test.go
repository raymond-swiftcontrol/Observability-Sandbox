package aggregate

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/calendar"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/clock"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
	"github.com/shopspring/decimal"
)

// recordingMetrics captures counts for assertions instead of talking to OTel.
type recordingMetrics struct {
	mu   sync.Mutex
	bars int
	late map[string]int
}

func newRecordingMetrics() *recordingMetrics {
	return &recordingMetrics{late: map[string]int{}}
}
func (m *recordingMetrics) BarEmitted() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.bars++
}
func (m *recordingMetrics) LateTick(disposition string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.late[disposition]++
}
func (m *recordingMetrics) get(disposition string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.late[disposition]
}

// collectSink appends every emitted bar, guarded by a mutex so it is race-safe
// when Run's goroutine and the test both touch it.
type collectSink struct {
	mu   sync.Mutex
	bars []model.Bar
	ch   chan model.Bar // optional: used by tests that synchronise via a channel
}

func newCollectSink() *collectSink { return &collectSink{ch: make(chan model.Bar, 64)} }

func (s *collectSink) EmitBar(_ context.Context, bar model.Bar) error {
	s.mu.Lock()
	s.bars = append(s.bars, bar)
	s.mu.Unlock()
	s.ch <- bar
	return nil
}

func (s *collectSink) snapshot() []model.Bar {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]model.Bar, len(s.bars))
	copy(out, s.bars)
	return out
}

func px(s string) decimal.Decimal { return decimal.RequireFromString(s) }

// regularSessionCalendar resolves every instrument against the real NYSE
// weekly schedule, so tests exercise the same pre/regular/post boundaries
// production does.
func nyCalendar() calendar.Calendar {
	return calendar.NewSet(calendar.USEquities())
}

func mustNYTime(t *testing.T, s string) time.Time {
	t.Helper()
	loc, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Fatalf("load America/New_York: %v", err)
	}
	tm, err := time.ParseInLocation("2006-01-02 15:04:05", s, loc)
	if err != nil {
		t.Fatalf("parse %q: %v", s, err)
	}
	return tm
}

func trade(instID uuid.UUID, symbol string, ts time.Time, price, size string) *model.Trade {
	return &model.Trade{
		TS: ts, InstrumentID: instID, Symbol: symbol,
		Price: px(price), Size: px(size), Quality: model.QualityVendor,
	}
}

// ── bucket boundary alignment ────────────────────────────────────────────────

func TestBucketBoundaryAlignment(t *testing.T) {
	t0 := mustNYTime(t, "2024-06-03 10:30:00").UTC()
	clk := clock.NewFake(t0)
	inst := uuid.New()
	sink := newCollectSink()
	agg := New(Config{Interval: time.Minute, Grace: time.Second}, clk, nyCalendar(), sink, nil, nil)
	ctx := context.Background()

	if err := agg.AddTrade(ctx, trade(inst, "AAPL", t0, "100.00", "10")); err != nil {
		t.Fatalf("AddTrade: %v", err)
	}
	if err := agg.AddTrade(ctx, trade(inst, "AAPL", t0.Add(59*time.Second), "100.10", "5")); err != nil {
		t.Fatalf("AddTrade: %v", err)
	}
	if got := agg.OpenCount(); got != 1 {
		t.Fatalf("expected both trades to land in one bucket, OpenCount=%d", got)
	}

	// A trade exactly on the next minute boundary must open a distinct bucket.
	if err := agg.AddTrade(ctx, trade(inst, "AAPL", t0.Add(60*time.Second), "100.20", "1")); err != nil {
		t.Fatalf("AddTrade: %v", err)
	}
	if got := agg.OpenCount(); got != 2 {
		t.Fatalf("expected the boundary trade to open a new bucket, OpenCount=%d", got)
	}

	key0 := instKey{id: inst, start: t0.UnixNano()}
	key1 := instKey{id: inst, start: t0.Add(60 * time.Second).UnixNano()}
	if _, ok := agg.open[key0]; !ok {
		t.Fatalf("bucket for minute 0 not found at truncated key")
	}
	if _, ok := agg.open[key1]; !ok {
		t.Fatalf("bucket for minute 1 not found at truncated key")
	}
}

// ── late tick: inside vs outside the grace window ───────────────────────────

func TestLateTickWithinGraceIsFolded(t *testing.T) {
	t0 := mustNYTime(t, "2024-06-03 10:30:00").UTC()
	clk := clock.NewFake(t0)
	inst := uuid.New()
	sink := newCollectSink()
	metrics := newRecordingMetrics()
	agg := New(Config{Interval: time.Minute, Grace: 3 * time.Second}, clk, nyCalendar(), sink, metrics, nil)
	ctx := context.Background()

	if err := agg.AddTrade(ctx, trade(inst, "AAPL", t0, "100.00", "10")); err != nil {
		t.Fatalf("AddTrade: %v", err)
	}

	// Advance the wall clock past the bucket's nominal close (t0+1m) but
	// inside the 3s grace window, then fold in a late trade for that bucket.
	clk.Advance(61 * time.Second)
	late := trade(inst, "AAPL", t0.Add(30*time.Second), "101.00", "2")
	if err := agg.AddTrade(ctx, late); err != nil {
		t.Fatalf("AddTrade late: %v", err)
	}
	if got := metrics.get(DispositionFolded); got != 1 {
		t.Fatalf("expected 1 folded late tick, got %d", got)
	}
	if got := metrics.get(DispositionDropped); got != 0 {
		t.Fatalf("expected 0 dropped late ticks, got %d", got)
	}

	// Now push past the grace deadline (t0+1m+3s) and close it.
	closeAt := t0.Add(65 * time.Second)
	bars, err := agg.CheckCloses(ctx, closeAt)
	if err != nil {
		t.Fatalf("CheckCloses: %v", err)
	}
	if len(bars) != 1 {
		t.Fatalf("expected exactly 1 bar closed, got %d", len(bars))
	}
	if !bars[0].High.Equal(px("101.00")) {
		t.Fatalf("expected the folded late trade to raise the high to 101.00, got %s", bars[0].High)
	}
	if bars[0].TradeCount != 2 {
		t.Fatalf("expected trade_count=2 (original + late), got %d", bars[0].TradeCount)
	}
}

func TestLateTickBeyondGraceIsDropped(t *testing.T) {
	t0 := mustNYTime(t, "2024-06-03 10:30:00").UTC()
	clk := clock.NewFake(t0)
	inst := uuid.New()
	sink := newCollectSink()
	metrics := newRecordingMetrics()
	agg := New(Config{Interval: time.Minute, Grace: 3 * time.Second}, clk, nyCalendar(), sink, metrics, nil)
	ctx := context.Background()

	if err := agg.AddTrade(ctx, trade(inst, "AAPL", t0, "100.00", "10")); err != nil {
		t.Fatalf("AddTrade: %v", err)
	}
	// Close the bucket for real.
	if _, err := agg.CheckCloses(ctx, t0.Add(64*time.Second)); err != nil {
		t.Fatalf("CheckCloses: %v", err)
	}
	if got := sink.snapshot(); len(got) != 1 {
		t.Fatalf("expected the on-time bucket to close, got %d bars", len(got))
	}

	// A trade for the same (now long-closed) bucket, arriving with the clock
	// well past the deadline, must be dropped rather than reopen the bucket.
	clk.Set(t0.Add(90 * time.Second))
	dropped := trade(inst, "AAPL", t0.Add(45*time.Second), "999.00", "1")
	if err := agg.AddTrade(ctx, dropped); err != nil {
		t.Fatalf("AddTrade: %v", err)
	}
	if got := metrics.get(DispositionDropped); got != 1 {
		t.Fatalf("expected 1 dropped late tick, got %d", got)
	}
	if got := agg.OpenCount(); got != 0 {
		t.Fatalf("dropping a late tick must not reopen a bucket, OpenCount=%d", got)
	}
	if got := len(sink.snapshot()); got != 1 {
		t.Fatalf("a dropped tick must not emit a second, corrected bar, got %d bars", got)
	}
}

// ── quiet symbol closes on the clock, not on the next tick ─────────────────

func TestQuietSymbolClosesOnClock(t *testing.T) {
	t0 := mustNYTime(t, "2024-06-03 10:30:00").UTC()
	clk := clock.NewFake(t0)
	inst := uuid.New()
	sink := newCollectSink()
	agg := New(Config{Interval: time.Minute, Grace: time.Second, CloseCheck: 250 * time.Millisecond},
		clk, nyCalendar(), sink, nil, nil)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runErr := make(chan error, 1)
	go func() { runErr <- agg.Run(ctx) }()

	if err := agg.AddTrade(ctx, trade(inst, "AAPL", t0, "50.00", "3")); err != nil {
		t.Fatalf("AddTrade: %v", err)
	}

	// Wait for Run's ticker to actually be registered with the fake clock
	// before advancing it, otherwise the advance could race ahead of the
	// goroutine subscribing.
	clk.BlockUntilPending(1)
	// No further trades arrive for this symbol: it has gone quiet. Advancing
	// the clock alone must still close and emit the bar.
	clk.Advance(2 * time.Minute)

	select {
	case bar := <-sink.ch:
		if bar.Symbol != "AAPL" || !bar.Close.Equal(px("50.00")) {
			t.Fatalf("unexpected bar emitted for quiet symbol: %+v", bar)
		}
		if !bar.Final {
			t.Fatalf("expected a clock-closed bar to be final")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for the quiet symbol's bar; bucket close is not clock-driven")
	}

	cancel()
	select {
	case err := <-runErr:
		if err != nil && err != context.Canceled {
			t.Fatalf("Run returned unexpected error: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not shut down after cancel")
	}
}

// ── session tagging across pre → regular → post ─────────────────────────────

func TestSessionTaggingAcrossTransitions(t *testing.T) {
	inst := uuid.New()
	sink := newCollectSink()
	cal := nyCalendar()
	clk := clock.NewFake(mustNYTime(t, "2024-06-03 04:00:00").UTC())
	agg := New(Config{Interval: time.Minute, Grace: time.Second}, clk, cal, sink, nil, nil)
	ctx := context.Background()

	cases := []struct {
		at   string
		want model.Session
	}{
		{"2024-06-03 07:15:00", model.SessionPre},
		{"2024-06-03 09:30:00", model.SessionRegular},
		{"2024-06-03 15:59:00", model.SessionRegular},
		{"2024-06-03 16:00:00", model.SessionPost},
		{"2024-06-03 19:59:00", model.SessionPost},
	}
	for _, c := range cases {
		ts := mustNYTime(t, c.at).UTC()
		if err := agg.AddTrade(ctx, trade(inst, "AAPL", ts, "10.00", "1")); err != nil {
			t.Fatalf("AddTrade at %s: %v", c.at, err)
		}
		bars, err := agg.CheckCloses(ctx, ts.Add(2*time.Minute))
		if err != nil {
			t.Fatalf("CheckCloses at %s: %v", c.at, err)
		}
		if len(bars) != 1 {
			t.Fatalf("at %s: expected 1 bar, got %d", c.at, len(bars))
		}
		if bars[0].Session != c.want {
			t.Fatalf("at %s: expected session %s, got %s", c.at, c.want, bars[0].Session)
		}
	}
}

// ── VWAP arithmetic ──────────────────────────────────────────────────────────

func TestVWAPArithmetic(t *testing.T) {
	t0 := mustNYTime(t, "2024-06-03 10:30:00").UTC()
	clk := clock.NewFake(t0)
	inst := uuid.New()
	sink := newCollectSink()
	agg := New(Config{Interval: time.Minute, Grace: time.Second}, clk, nyCalendar(), sink, nil, nil)
	ctx := context.Background()

	// (100*10 + 101*20 + 99*5) / (10+20+5) = (1000+2020+495)/35 = 3515/35 = 100.42857142857...
	trades := []struct{ price, size string }{
		{"100", "10"},
		{"101", "20"},
		{"99", "5"},
	}
	for _, tr := range trades {
		if err := agg.AddTrade(ctx, trade(inst, "AAPL", t0.Add(time.Second), tr.price, tr.size)); err != nil {
			t.Fatalf("AddTrade: %v", err)
		}
	}
	bars, err := agg.CheckCloses(ctx, t0.Add(2*time.Minute))
	if err != nil {
		t.Fatalf("CheckCloses: %v", err)
	}
	if len(bars) != 1 {
		t.Fatalf("expected 1 bar, got %d", len(bars))
	}
	wantNum := px("1000").Add(px("2020")).Add(px("495"))
	wantDen := px("35")
	want := wantNum.Div(wantDen)
	if !bars[0].VWAP.Equal(want) {
		t.Fatalf("VWAP = %s, want %s", bars[0].VWAP, want)
	}
	if !bars[0].Volume.Equal(wantDen) {
		t.Fatalf("Volume = %s, want %s", bars[0].Volume, wantDen)
	}
}

// ── out-of-order tick ────────────────────────────────────────────────────────

func TestOutOfOrderTick(t *testing.T) {
	t0 := mustNYTime(t, "2024-06-03 10:30:00").UTC()
	clk := clock.NewFake(t0)
	inst := uuid.New()
	sink := newCollectSink()
	agg := New(Config{Interval: time.Minute, Grace: time.Second}, clk, nyCalendar(), sink, nil, nil)
	ctx := context.Background()

	// The trade with the LATER timestamp arrives FIRST.
	later := trade(inst, "AAPL", t0.Add(45*time.Second), "105.00", "1")
	earlier := trade(inst, "AAPL", t0.Add(5*time.Second), "95.00", "1")
	if err := agg.AddTrade(ctx, later); err != nil {
		t.Fatalf("AddTrade: %v", err)
	}
	if err := agg.AddTrade(ctx, earlier); err != nil {
		t.Fatalf("AddTrade: %v", err)
	}

	bars, err := agg.CheckCloses(ctx, t0.Add(2*time.Minute))
	if err != nil {
		t.Fatalf("CheckCloses: %v", err)
	}
	if len(bars) != 1 {
		t.Fatalf("expected 1 bar, got %d", len(bars))
	}
	bar := bars[0]
	if !bar.Open.Equal(px("95.00")) {
		t.Fatalf("Open should come from the earlier-timestamped trade despite arriving second, got %s", bar.Open)
	}
	if !bar.Close.Equal(px("105.00")) {
		t.Fatalf("Close should come from the later-timestamped trade despite arriving first, got %s", bar.Close)
	}
	if !bar.High.Equal(px("105.00")) || !bar.Low.Equal(px("95.00")) {
		t.Fatalf("High/Low incorrect: high=%s low=%s", bar.High, bar.Low)
	}
}
