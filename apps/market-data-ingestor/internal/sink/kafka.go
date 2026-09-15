// Package sink owns everything downstream of normalisation: publishing the
// canonical event stream to Kafka and persisting it to TimescaleDB.
//
// The two halves have different failure philosophies on purpose. Kafka
// backpressures — Publish blocks the caller once its bounded buffer is full,
// because refusing to accept a tick faster than the broker can take it is
// cheap and reversible (the vendor session's own read loop simply slows
// down). The database writer cannot do that without stalling the whole
// pipeline behind a schema it does not control, so past its buffer bound it
// sheds instead: see timescale.go for why that is the honest choice.
package sink

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"log/slog"
	"sync"
	"time"

	"github.com/segmentio/kafka-go"
	"github.com/segmentio/kafka-go/compress"
)

// Metrics receives the sink's counters. A narrow interface (rather than
// *telemetry.Metrics) so this package tests without a meter provider, the
// same convention internal/normalize and internal/aggregate use.
type Metrics interface {
	KafkaProduced(topic string)
	KafkaError(topic string)
	DBBatchRows(rows int, dur time.Duration)
	DBShed(n int)
	DBBuffered(delta int)
}

type nopMetrics struct{}

func (nopMetrics) KafkaProduced(string)            {}
func (nopMetrics) KafkaError(string)               {}
func (nopMetrics) DBBatchRows(int, time.Duration)  {}
func (nopMetrics) DBShed(int)                      {}
func (nopMetrics) DBBuffered(int)                  {}

// ErrProducerClosed is returned by Publish once Close has been called.
var ErrProducerClosed = errors.New("sink: kafka producer is closed")

// Writer is the subset of *kafka.Writer this package depends on, narrowed so
// tests can substitute a fake broker-free implementation.
type Writer interface {
	WriteMessages(ctx context.Context, msgs ...kafka.Message) error
	Close() error
}

// KafkaConfig configures the producer. Field names mirror config.KafkaConfig
// so callers pass it straight through.
type KafkaConfig struct {
	Brokers        []string
	ClientID       string
	ProduceTimeout time.Duration
	Compression    string
	// MaxBuffered bounds the total number of messages queued but not yet
	// acknowledged, spread evenly across Lanes. Publish blocks once the
	// destination lane is full — that is the backpressure.
	MaxBuffered int
	// Lanes is the number of independent, strictly-ordered send queues. A
	// message's lane is a hash of its key, so every message for a given
	// instrument always travels through the same lane in the order Publish
	// was called with it — the per-symbol ordering guarantee — while
	// different instruments fan out across lanes for throughput. Zero
	// defaults to 8.
	Lanes int
}

func (c *KafkaConfig) withDefaults() {
	if c.MaxBuffered <= 0 {
		c.MaxBuffered = 50000
	}
	if c.Lanes <= 0 {
		c.Lanes = 8
	}
	if c.ProduceTimeout <= 0 {
		c.ProduceTimeout = 10 * time.Second
	}
}

// NewWriter builds the real *kafka.Writer used in production. Balancer is
// Hash{} deliberately: kafka-go's default balancer (round robin) ignores the
// message key entirely, which would silently defeat the per-instrument
// ordering this package exists to provide.
func NewWriter(cfg KafkaConfig) *kafka.Writer {
	cfg.withDefaults()
	w := &kafka.Writer{
		Addr:         kafka.TCP(cfg.Brokers...),
		Balancer:     &kafka.Hash{},
		RequiredAcks: kafka.RequireOne,
		BatchTimeout: 25 * time.Millisecond,
		Async:        false, // ordering is enforced by our own lanes; see below
		ClientID:     "", // ClientID has no direct Writer field; carried via Transport if needed
		Compression:  compressionCodec(cfg.Compression),
	}
	return w
}

func compressionCodec(name string) kafka.Compression {
	switch name {
	case "gzip":
		return kafka.Gzip
	case "snappy":
		return kafka.Snappy
	case "lz4":
		return kafka.Lz4
	case "zstd", "":
		return kafka.Zstd
	default:
		return kafka.Zstd
	}
}

// staticCompressionCodec is referenced only to keep the compress import used
// for documentation of the supported codec set in one place; kafka.Writer's
// Compression field above is what actually configures it.
var _ = compress.Zstd

// KafkaProducer is an async, per-key-ordered Kafka publisher with bounded
// buffering and backpressure.
//
// Why lanes rather than kafka-go's own Async mode: Async mode queues
// messages internally with no caller-visible bound, so a slow or unreachable
// broker turns into unbounded memory growth exactly like the failure this
// package is designed to avoid on the database side. Routing by key hash
// into a small, fixed number of bounded, strictly sequential channels gives
// the same ordering guarantee kafka-go's own Hash balancer gives at the
// partition level, plus an explicit, finite buffer whose fullness is the
// backpressure signal callers feel directly in Publish.
type KafkaProducer struct {
	writer  Writer
	cfg     KafkaConfig
	metrics Metrics
	logger  *slog.Logger

	lanes []chan laneMsg
	wg    sync.WaitGroup

	closeOnce sync.Once
	done      chan struct{}
}

type laneMsg struct {
	topic string
	key   []byte
	value []byte
}

// NewKafkaProducer builds a producer over writer. Call Start before the first
// Publish.
func NewKafkaProducer(writer Writer, cfg KafkaConfig, metrics Metrics, logger *slog.Logger) *KafkaProducer {
	cfg.withDefaults()
	if metrics == nil {
		metrics = nopMetrics{}
	}
	if logger == nil {
		logger = slog.Default()
	}
	p := &KafkaProducer{
		writer:  writer,
		cfg:     cfg,
		metrics: metrics,
		logger:  logger,
		done:    make(chan struct{}),
	}
	perLane := cfg.MaxBuffered / cfg.Lanes
	if perLane < 1 {
		perLane = 1
	}
	p.lanes = make([]chan laneMsg, cfg.Lanes)
	for i := range p.lanes {
		p.lanes[i] = make(chan laneMsg, perLane)
	}
	return p
}

// Start launches one worker goroutine per lane. It must be called exactly
// once, before the first Publish, and paired with Close.
func (p *KafkaProducer) Start(ctx context.Context) {
	for i := range p.lanes {
		p.wg.Add(1)
		go p.runLane(ctx, i)
	}
}

func (p *KafkaProducer) runLane(ctx context.Context, i int) {
	defer p.wg.Done()
	for msg := range p.lanes[i] {
		p.send(ctx, msg)
	}
}

func (p *KafkaProducer) send(ctx context.Context, msg laneMsg) {
	sendCtx, cancel := context.WithTimeout(ctx, p.cfg.ProduceTimeout)
	defer cancel()
	err := p.writer.WriteMessages(sendCtx, kafka.Message{
		Topic: msg.topic, Key: msg.key, Value: msg.value, Time: time.Now(),
	})
	if err != nil {
		p.metrics.KafkaError(msg.topic)
		p.logger.ErrorContext(ctx, "kafka publish failed", slog.String("topic", msg.topic), slog.Any("error", err))
		return
	}
	p.metrics.KafkaProduced(msg.topic)
}

func (p *KafkaProducer) laneFor(key []byte) int {
	if len(key) == 0 {
		return 0
	}
	h := fnv.New32a()
	_, _ = h.Write(key)
	return int(h.Sum32() % uint32(len(p.lanes)))
}

// Publish enqueues one record, blocking if its lane's buffer is full (the
// backpressure this type exists to provide) until space frees up or ctx is
// cancelled. Messages sharing the same key are always handed to the
// underlying writer in the order Publish was called for them.
func (p *KafkaProducer) Publish(ctx context.Context, topic string, key, value []byte) error {
	select {
	case <-p.done:
		return ErrProducerClosed
	default:
	}
	lane := p.lanes[p.laneFor(key)]
	select {
	case lane <- laneMsg{topic: topic, key: key, value: value}:
		return nil
	case <-p.done:
		return ErrProducerClosed
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Close stops accepting new messages, drains every lane and closes the
// underlying writer. It blocks until draining completes or ctx is done.
func (p *KafkaProducer) Close(ctx context.Context) error {
	p.closeOnce.Do(func() {
		close(p.done)
		for _, l := range p.lanes {
			close(l)
		}
	})
	drained := make(chan struct{})
	go func() { p.wg.Wait(); close(drained) }()
	select {
	case <-drained:
	case <-ctx.Done():
		return fmt.Errorf("sink: kafka producer drain timed out: %w", ctx.Err())
	}
	return p.writer.Close()
}

// Buffered reports how many messages are currently queued across all lanes,
// for diagnostics and tests.
func (p *KafkaProducer) Buffered() int {
	n := 0
	for _, l := range p.lanes {
		n += len(l)
	}
	return n
}
