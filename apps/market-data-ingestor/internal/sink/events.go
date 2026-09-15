package sink

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/normalize"
	"github.com/shopspring/decimal"
)

// Topics names the Kafka destinations. Field values must match
// scripts/init-topics.sh exactly; config.KafkaConfig is the source of truth
// callers wire in.
type Topics struct {
	Ticks  string // trades AND quotes: config.KafkaConfig.TopicTicks == TopicQuotes
	Quotes string
	Bars   string
	Book   string
	DLQ    string
}

// EventSink is the Kafka-facing implementation of aggregate.Sink,
// book.Sink and normalize.DLQ, plus the raw trade/quote/book-delta
// publication path. Centralising all four here means the topic-routing and
// wire-encoding decisions live in one file instead of being duplicated
// against every consumer of KafkaProducer.
type EventSink struct {
	producer *KafkaProducer
	topics   Topics
}

// NewEventSink builds an EventSink over an already-Start'ed producer.
func NewEventSink(producer *KafkaProducer, topics Topics) *EventSink {
	return &EventSink{producer: producer, topics: topics}
}

// PublishEvent routes one canonical event to its topic, keyed by instrument
// id for per-symbol ordering. Bars are published through EmitBar instead
// (aggregate.Sink), not through this path.
func (s *EventSink) PublishEvent(ctx context.Context, ev model.Event) error {
	key := []byte(ev.InstrumentID().String())
	switch ev.Kind {
	case model.KindTrade:
		payload, err := json.Marshal(wireTrade{
			TS: ev.Trade.TS, InstrumentID: ev.Trade.InstrumentID.String(), Symbol: ev.Trade.Symbol,
			Price: ev.Trade.Price, Size: ev.Trade.Size, TradeID: ev.Trade.TradeID,
			VenueID: ev.Trade.VenueID, Aggressor: ev.Trade.Aggressor, Conditions: ev.Trade.Conditions,
			ExchangeTS: ev.Trade.ExchangeTS, Quality: ev.Trade.Quality, Vendor: ev.Trade.Vendor, Sequence: ev.Trade.Sequence,
		})
		if err != nil {
			return fmt.Errorf("sink: marshal trade: %w", err)
		}
		return s.producer.Publish(ctx, s.topics.Ticks, key, payload)

	case model.KindQuote:
		payload, err := json.Marshal(wireQuote{
			TS: ev.Quote.TS, InstrumentID: ev.Quote.InstrumentID.String(), Symbol: ev.Quote.Symbol,
			BidPrice: ev.Quote.BidPrice, BidSize: ev.Quote.BidSize, AskPrice: ev.Quote.AskPrice, AskSize: ev.Quote.AskSize,
			BidVenueID: ev.Quote.BidVenueID, AskVenueID: ev.Quote.AskVenueID,
			ExchangeTS: ev.Quote.ExchangeTS, Vendor: ev.Quote.Vendor, Sequence: ev.Quote.Sequence,
		})
		if err != nil {
			return fmt.Errorf("sink: marshal quote: %w", err)
		}
		return s.producer.Publish(ctx, s.topics.Quotes, key, payload)

	case model.KindBookDelta:
		return s.publishBookDelta(ctx, ev.Book)

	default:
		return nil
	}
}

func (s *EventSink) publishBookDelta(ctx context.Context, d *model.BookDelta) error {
	payload, err := json.Marshal(wireBookDelta{
		TS: d.TS, InstrumentID: d.InstrumentID.String(), Symbol: d.Symbol,
		Sequence: d.Sequence, PrevSequence: d.PrevSequence, Snapshot: d.Snapshot,
		Bids: d.Bids, Asks: d.Asks, Vendor: d.Vendor,
	})
	if err != nil {
		return fmt.Errorf("sink: marshal book delta: %w", err)
	}
	return s.producer.Publish(ctx, s.topics.Book, []byte(d.InstrumentID.String()), payload)
}

// EmitBar implements aggregate.Sink.
func (s *EventSink) EmitBar(ctx context.Context, bar model.Bar) error {
	payload, err := json.Marshal(wireBar{
		TS: bar.TS, InstrumentID: bar.InstrumentID.String(), Symbol: bar.Symbol,
		Open: bar.Open, High: bar.High, Low: bar.Low, Close: bar.Close,
		Volume: bar.Volume, TradeCount: bar.TradeCount, VWAP: bar.VWAP,
		Session: bar.Session, Quality: bar.Quality, Source: bar.Source,
		IntervalSeconds: int64(bar.Interval.Seconds()), Final: bar.Final,
	})
	if err != nil {
		return fmt.Errorf("sink: marshal bar: %w", err)
	}
	return s.producer.Publish(ctx, s.topics.Bars, []byte(bar.InstrumentID.String()), payload)
}

// EmitBookSnapshot implements book.Sink.
func (s *EventSink) EmitBookSnapshot(ctx context.Context, snap model.BookSnapshot) error {
	payload, err := json.Marshal(wireBookSnapshot{
		TS: snap.TS, InstrumentID: snap.InstrumentID.String(), Symbol: snap.Symbol,
		Sequence: snap.Sequence, Bids: snap.Bids, Asks: snap.Asks, DepthLevels: snap.DepthLevels,
		ImbalanceL1: snap.ImbalanceL1, ImbalanceL5: snap.ImbalanceL5,
	})
	if err != nil {
		return fmt.Errorf("sink: marshal book snapshot: %w", err)
	}
	return s.producer.Publish(ctx, s.topics.Book, []byte(snap.InstrumentID.String()), payload)
}

// PublishReject implements normalize.DLQ. Rejects are keyed by vendor+symbol
// rather than instrument id (which the normaliser could not resolve, or the
// message would not be rejected) so that a storm of bad messages for one
// vendor symbol still lands in order on one partition for triage.
func (s *EventSink) PublishReject(ctx context.Context, r normalize.Reject) error {
	payload, err := json.Marshal(r)
	if err != nil {
		return fmt.Errorf("sink: marshal reject: %w", err)
	}
	key := []byte(r.Vendor + "/" + r.Symbol)
	return s.producer.Publish(ctx, s.topics.DLQ, key, payload)
}

// ── wire types ───────────────────────────────────────────────────────────────
// Deliberately separate from internal/model: these are the Kafka wire
// contract and gain json tags and field renames independently of the
// canonical in-process types. decimal.Decimal marshals as a quoted string by
// default, matching the "never a float on the wire" rule applied everywhere
// else in this service.

type wireTrade struct {
	TS           time.Time       `json:"ts"`
	InstrumentID string          `json:"instrument_id"`
	Symbol       string          `json:"symbol"`
	Price        decimal.Decimal `json:"price"`
	Size         decimal.Decimal `json:"size"`
	TradeID      string          `json:"trade_id,omitempty"`
	VenueID      int16           `json:"venue_id"`
	Aggressor    model.Side      `json:"aggressor,omitempty"`
	Conditions   []string        `json:"conditions,omitempty"`
	ExchangeTS   time.Time       `json:"exchange_ts"`
	Quality      model.Quality   `json:"quality"`
	Vendor       string          `json:"vendor"`
	Sequence     int64           `json:"sequence"`
}

type wireQuote struct {
	TS           time.Time       `json:"ts"`
	InstrumentID string          `json:"instrument_id"`
	Symbol       string          `json:"symbol"`
	BidPrice     decimal.Decimal `json:"bid_price"`
	BidSize      decimal.Decimal `json:"bid_size"`
	AskPrice     decimal.Decimal `json:"ask_price"`
	AskSize      decimal.Decimal `json:"ask_size"`
	BidVenueID   int16           `json:"bid_venue_id"`
	AskVenueID   int16           `json:"ask_venue_id"`
	ExchangeTS   time.Time       `json:"exchange_ts"`
	Vendor       string          `json:"vendor"`
	Sequence     int64           `json:"sequence"`
}

type wireBar struct {
	TS              time.Time       `json:"ts"`
	InstrumentID    string          `json:"instrument_id"`
	Symbol          string          `json:"symbol"`
	Open            decimal.Decimal `json:"open"`
	High            decimal.Decimal `json:"high"`
	Low             decimal.Decimal `json:"low"`
	Close           decimal.Decimal `json:"close"`
	Volume          decimal.Decimal `json:"volume"`
	TradeCount      int32           `json:"trade_count"`
	VWAP            decimal.Decimal `json:"vwap"`
	Session         model.Session   `json:"session"`
	Quality         model.Quality   `json:"quality"`
	Source          string          `json:"source"`
	IntervalSeconds int64           `json:"interval_seconds"`
	Final           bool            `json:"final"`
}

type wireBookDelta struct {
	TS           time.Time         `json:"ts"`
	InstrumentID string            `json:"instrument_id"`
	Symbol       string            `json:"symbol"`
	Sequence     int64             `json:"sequence"`
	PrevSequence int64             `json:"prev_sequence"`
	Snapshot     bool              `json:"snapshot"`
	Bids         []model.BookLevel `json:"bids"`
	Asks         []model.BookLevel `json:"asks"`
	Vendor       string            `json:"vendor"`
}

type wireBookSnapshot struct {
	TS           time.Time         `json:"ts"`
	InstrumentID string            `json:"instrument_id"`
	Symbol       string            `json:"symbol"`
	Sequence     int64             `json:"sequence"`
	Bids         []model.BookLevel `json:"bids"`
	Asks         []model.BookLevel `json:"asks"`
	DepthLevels  int16             `json:"depth_levels"`
	ImbalanceL1  decimal.Decimal   `json:"imbalance_l1"`
	ImbalanceL5  decimal.Decimal   `json:"imbalance_l5"`
}
