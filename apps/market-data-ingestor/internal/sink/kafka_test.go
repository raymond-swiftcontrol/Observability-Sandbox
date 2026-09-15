package sink

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/segmentio/kafka-go"
)

// fakeWriter records every WriteMessages call. An optional per-topic delay
// lets tests exercise backpressure without a real broker, and failFor makes
// specific keys fail so metrics/error-path tests do not need a live Kafka.
type fakeWriter struct {
	mu      sync.Mutex
	sent    []kafka.Message
	delay   time.Duration
	failKey string // messages with this key (as string) return an error
	closed  bool
}

func (f *fakeWriter) WriteMessages(ctx context.Context, msgs ...kafka.Message) error {
	if f.delay > 0 {
		select {
		case <-time.After(f.delay):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, m := range msgs {
		if f.failKey != "" && string(m.Key) == f.failKey {
			return errors.New("fake: simulated broker rejection")
		}
	}
	f.sent = append(f.sent, msgs...)
	return nil
}

func (f *fakeWriter) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closed = true
	return nil
}

func (f *fakeWriter) snapshot() []kafka.Message {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]kafka.Message, len(f.sent))
	copy(out, f.sent)
	return out
}

type fakeSinkMetrics struct {
	mu        sync.Mutex
	produced  map[string]int
	errors    map[string]int
	shed      int
	batchRows []int
}

func newFakeSinkMetrics() *fakeSinkMetrics {
	return &fakeSinkMetrics{produced: map[string]int{}, errors: map[string]int{}}
}
func (m *fakeSinkMetrics) KafkaProduced(topic string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.produced[topic]++
}
func (m *fakeSinkMetrics) KafkaError(topic string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.errors[topic]++
}
func (m *fakeSinkMetrics) DBBatchRows(rows int, _ time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.batchRows = append(m.batchRows, rows)
}
func (m *fakeSinkMetrics) DBShed(n int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.shed += n
}
func (m *fakeSinkMetrics) DBBuffered(int) {}

func (m *fakeSinkMetrics) getProduced(topic string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.produced[topic]
}

// ── ordering preserved per key ───────────────────────────────────────────────

func TestKafkaProducerOrderingPreservedPerKey(t *testing.T) {
	fw := &fakeWriter{}
	metrics := newFakeSinkMetrics()
	p := NewKafkaProducer(fw, KafkaConfig{MaxBuffered: 100, Lanes: 4}, metrics, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p.Start(ctx)

	key := []byte("inst-A")
	const n = 200
	for i := 0; i < n; i++ {
		if err := p.Publish(ctx, "md.ticks.v1", key, []byte{byte(i), byte(i >> 8)}); err != nil {
			t.Fatalf("Publish %d: %v", i, err)
		}
	}
	if err := p.Close(context.Background()); err != nil {
		t.Fatalf("Close: %v", err)
	}

	sent := fw.snapshot()
	if len(sent) != n {
		t.Fatalf("expected %d messages sent, got %d", n, len(sent))
	}
	for i, m := range sent {
		want := []byte{byte(i), byte(i >> 8)}
		if string(m.Value) != string(want) {
			t.Fatalf("message %d out of order: got value %v, want %v", i, m.Value, want)
		}
	}
	if got := metrics.getProduced("md.ticks.v1"); got != n {
		t.Fatalf("expected %d produced metric increments, got %d", n, got)
	}
}

func TestKafkaProducerDifferentKeysDoNotBlockEachOther(t *testing.T) {
	fw := &fakeWriter{}
	p := NewKafkaProducer(fw, KafkaConfig{MaxBuffered: 80, Lanes: 8}, nil, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p.Start(ctx)

	for i := 0; i < 500; i++ {
		key := []byte{byte(i % 16)}
		if err := p.Publish(ctx, "md.ticks.v1", key, []byte("v")); err != nil {
			t.Fatalf("Publish: %v", err)
		}
	}
	if err := p.Close(context.Background()); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if got := len(fw.snapshot()); got != 500 {
		t.Fatalf("expected all 500 messages delivered, got %d", got)
	}
}

// ── backpressure: Publish blocks once the lane is full ─────────────────────

func TestKafkaProducerBackpressureBlocksUntilContextDeadline(t *testing.T) {
	fw := &fakeWriter{delay: 200 * time.Millisecond}
	// A single lane, capacity 1: the second Publish fills the lane buffer,
	// the third must block behind the slow in-flight send.
	p := NewKafkaProducer(fw, KafkaConfig{MaxBuffered: 1, Lanes: 1}, nil, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p.Start(ctx)

	if err := p.Publish(ctx, "t", []byte("k"), []byte("1")); err != nil {
		t.Fatalf("Publish 1: %v", err)
	}
	if err := p.Publish(ctx, "t", []byte("k"), []byte("2")); err != nil {
		t.Fatalf("Publish 2: %v", err)
	}

	blockedCtx, blockedCancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer blockedCancel()
	err := p.Publish(blockedCtx, "t", []byte("k"), []byte("3"))
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected the third publish to block until the deadline (backpressure), got %v", err)
	}

	if err := p.Close(context.Background()); err != nil {
		t.Fatalf("Close: %v", err)
	}
}

func TestKafkaProducerPublishAfterCloseFails(t *testing.T) {
	fw := &fakeWriter{}
	p := NewKafkaProducer(fw, KafkaConfig{MaxBuffered: 10, Lanes: 1}, nil, nil)
	ctx := context.Background()
	p.Start(ctx)
	if err := p.Close(ctx); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := p.Publish(ctx, "t", []byte("k"), []byte("v")); !errors.Is(err, ErrProducerClosed) {
		t.Fatalf("expected ErrProducerClosed, got %v", err)
	}
	if !fw.closed {
		t.Fatalf("expected underlying writer to be closed")
	}
}

func TestKafkaProducerErrorIncrementsMetric(t *testing.T) {
	fw := &fakeWriter{failKey: "bad"}
	metrics := newFakeSinkMetrics()
	p := NewKafkaProducer(fw, KafkaConfig{MaxBuffered: 10, Lanes: 1, ProduceTimeout: time.Second}, metrics, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p.Start(ctx)

	if err := p.Publish(ctx, "md.ticks.v1", []byte("bad"), []byte("v")); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if err := p.Close(context.Background()); err != nil {
		t.Fatalf("Close: %v", err)
	}
	metrics.mu.Lock()
	got := metrics.errors["md.ticks.v1"]
	metrics.mu.Unlock()
	if got != 1 {
		t.Fatalf("expected 1 kafka error metric, got %d", got)
	}
}
