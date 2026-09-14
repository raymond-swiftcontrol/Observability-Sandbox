package telemetry

import (
	"context"
	"fmt"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

// Metrics is the ingestor's instrument set. Holding them on one struct keeps
// the cardinality decisions in one reviewable place: every label used here is
// bounded by the vendor/feed/topic/reason vocabularies, never by instrument id.
// A per-instrument counter across 8k instruments is how a Prometheus falls over.
type Metrics struct {
	Messages        metric.Int64Counter
	Bytes           metric.Int64Counter
	E2ELatency      metric.Float64Histogram
	SequenceGaps    metric.Int64Counter
	Reconnects      metric.Int64Counter
	BreakerOpens    metric.Int64Counter
	Rejects         metric.Int64Counter
	DLQPublished    metric.Int64Counter
	SymbolCache     metric.Int64Counter
	BarsEmitted     metric.Int64Counter
	LateTicks       metric.Int64Counter
	BookResyncs     metric.Int64Counter
	DBBatchRows     metric.Int64Histogram
	DBBatchDuration metric.Float64Histogram
	DBShedRows      metric.Int64Counter
	DBBuffered      metric.Int64UpDownCounter
	KafkaErrors     metric.Int64Counter
	KafkaProduced   metric.Int64Counter
	StreamClients   metric.Int64UpDownCounter
}

// NewMetrics registers every instrument against the supplied meter.
func NewMetrics(m metric.Meter) (*Metrics, error) {
	var err error
	out := &Metrics{}
	reg := func(name string, build func() error) {
		if err != nil {
			return
		}
		if e := build(); e != nil {
			err = fmt.Errorf("instrument %s: %w", name, e)
		}
	}

	reg("helios.md.messages", func() (e error) {
		out.Messages, e = m.Int64Counter("helios.md.messages",
			metric.WithDescription("Normalised market data messages, by vendor and feed"),
			metric.WithUnit("{message}"))
		return
	})
	reg("helios.md.bytes", func() (e error) {
		out.Bytes, e = m.Int64Counter("helios.md.bytes",
			metric.WithDescription("Raw vendor payload bytes received"), metric.WithUnit("By"))
		return
	})
	reg("helios.md.e2e_latency", func() (e error) {
		out.E2ELatency, e = m.Float64Histogram("helios.md.e2e_latency",
			metric.WithDescription("Exchange timestamp to Kafka publish, in seconds"),
			metric.WithUnit("s"),
			// Buckets span a co-located 200µs hop through a 30s stalled feed;
			// the default OTel buckets top out at 10s and would hide the tail
			// that actually pages someone.
			metric.WithExplicitBucketBoundaries(
				0.0002, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05,
				0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30))
		return
	})
	reg("helios.md.sequence_gaps", func() (e error) {
		out.SequenceGaps, e = m.Int64Counter("helios.md.sequence_gaps",
			metric.WithDescription("Detected vendor sequence discontinuities"), metric.WithUnit("{gap}"))
		return
	})
	reg("helios.md.reconnects", func() (e error) {
		out.Reconnects, e = m.Int64Counter("helios.md.reconnects",
			metric.WithDescription("Vendor websocket reconnect attempts"), metric.WithUnit("{reconnect}"))
		return
	})
	reg("helios.md.breaker_opens", func() (e error) {
		out.BreakerOpens, e = m.Int64Counter("helios.md.breaker_opens",
			metric.WithDescription("Circuit breaker transitions into open"), metric.WithUnit("{transition}"))
		return
	})
	reg("helios.md.rejects", func() (e error) {
		out.Rejects, e = m.Int64Counter("helios.md.rejects",
			metric.WithDescription("Messages failing normalisation or validation, by reason"),
			metric.WithUnit("{message}"))
		return
	})
	reg("helios.md.dlq_published", func() (e error) {
		out.DLQPublished, e = m.Int64Counter("helios.md.dlq_published",
			metric.WithDescription("Rejected messages successfully written to the DLQ topic"),
			metric.WithUnit("{message}"))
		return
	})
	reg("helios.md.symbol_cache", func() (e error) {
		out.SymbolCache, e = m.Int64Counter("helios.md.symbol_cache",
			metric.WithDescription("Vendor symbol resolution cache outcomes"), metric.WithUnit("{lookup}"))
		return
	})
	reg("helios.md.bars_emitted", func() (e error) {
		out.BarsEmitted, e = m.Int64Counter("helios.md.bars_emitted",
			metric.WithDescription("Bars emitted on bucket close"), metric.WithUnit("{bar}"))
		return
	})
	reg("helios.md.late_ticks", func() (e error) {
		out.LateTicks, e = m.Int64Counter("helios.md.late_ticks",
			metric.WithDescription("Ticks arriving after their bucket closed, by disposition"),
			metric.WithUnit("{tick}"))
		return
	})
	reg("helios.md.book_resyncs", func() (e error) {
		out.BookResyncs, e = m.Int64Counter("helios.md.book_resyncs",
			metric.WithDescription("L2 book resynchronisations triggered by a sequence gap"),
			metric.WithUnit("{resync}"))
		return
	})
	reg("helios.md.db_batch_rows", func() (e error) {
		out.DBBatchRows, e = m.Int64Histogram("helios.md.db_batch_rows",
			metric.WithDescription("Rows per CopyFrom batch"), metric.WithUnit("{row}"),
			metric.WithExplicitBucketBoundaries(1, 10, 50, 100, 500, 1000, 2500, 5000, 10000, 25000))
		return
	})
	reg("helios.md.db_batch_duration", func() (e error) {
		out.DBBatchDuration, e = m.Float64Histogram("helios.md.db_batch_duration",
			metric.WithDescription("CopyFrom batch wall time"), metric.WithUnit("s"),
			metric.WithExplicitBucketBoundaries(0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10))
		return
	})
	reg("helios.md.db_shed_rows", func() (e error) {
		out.DBShedRows, e = m.Int64Counter("helios.md.db_shed_rows",
			metric.WithDescription("Rows dropped after the persistence buffer filled"), metric.WithUnit("{row}"))
		return
	})
	reg("helios.md.db_buffered_rows", func() (e error) {
		out.DBBuffered, e = m.Int64UpDownCounter("helios.md.db_buffered_rows",
			metric.WithDescription("Rows currently buffered awaiting a database write"), metric.WithUnit("{row}"))
		return
	})
	reg("helios.md.kafka_errors", func() (e error) {
		out.KafkaErrors, e = m.Int64Counter("helios.md.kafka_errors",
			metric.WithDescription("Kafka produce failures, by topic"), metric.WithUnit("{error}"))
		return
	})
	reg("helios.md.kafka_produced", func() (e error) {
		out.KafkaProduced, e = m.Int64Counter("helios.md.kafka_produced",
			metric.WithDescription("Records acknowledged by Kafka, by topic"), metric.WithUnit("{record}"))
		return
	})
	reg("helios.md.stream_clients", func() (e error) {
		out.StreamClients, e = m.Int64UpDownCounter("helios.md.stream_clients",
			metric.WithDescription("Connected StreamQuotes subscribers"), metric.WithUnit("{client}"))
		return
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// VendorFeed is the attribute set used by almost every hot-path metric.
func VendorFeed(vendor, feed string) metric.MeasurementOption {
	return metric.WithAttributes(attribute.String("vendor", vendor), attribute.String("feed", feed))
}

// Reason labels rejects and shed events.
func Reason(reason string) metric.MeasurementOption {
	return metric.WithAttributes(attribute.String("reason", reason))
}

// Topic labels Kafka instruments.
func Topic(topic string) metric.MeasurementOption {
	return metric.WithAttributes(attribute.String("topic", topic))
}

// NoopContext is a tiny convenience so hot-path call sites read cleanly.
var NoopContext = context.Background
