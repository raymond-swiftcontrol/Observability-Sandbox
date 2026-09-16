package sink

import (
	"context"

	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/health"
)

// HealthSink adapts the two feed-health TableWriters to health.Sink, so
// main.go can wire internal/health straight into the batching writers
// everything else in this package already uses.
type HealthSink struct {
	FeedHealth *TableWriter[FeedHealthRow]
	DataGap    *TableWriter[DataGap]
}

// EmitFeedHealth implements health.Sink.
func (s *HealthSink) EmitFeedHealth(_ context.Context, row health.FeedHealthRow) error {
	s.FeedHealth.Add(FeedHealthRow{
		TS: row.TS, Vendor: row.Vendor, Feed: row.Feed,
		Messages: row.Messages, Bytes: row.Bytes,
		GapsDetected: row.GapsDetected, SequenceResets: row.SequenceResets,
		P50LatencyMs: row.P50LatencyMs, P99LatencyMs: row.P99LatencyMs, MaxLatencyMs: row.MaxLatencyMs,
		Reconnects: row.Reconnects, LastError: row.LastError,
	})
	return nil
}

// EmitDataGap implements health.Sink.
func (s *HealthSink) EmitDataGap(_ context.Context, gap health.DataGap) error {
	s.DataGap.Add(DataGap{
		InstrumentID: gap.InstrumentID, Feed: gap.Feed,
		GapStart: gap.GapStart, GapEnd: gap.GapEnd,
		ExpectedRows: gap.ExpectedRows, ActualRows: gap.ActualRows,
	})
	return nil
}
