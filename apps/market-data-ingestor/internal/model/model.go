// Package model holds the canonical, vendor-independent market data types.
//
// Every price and size is a decimal. The database columns are
// numeric(28,12)/numeric(38,18) (see db/migrations/0001) and float64 carries 53
// bits of mantissa, so a float round-trip through this package would silently
// corrupt crypto sizes and FX minor pairs long before anyone noticed.
package model

import (
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"
)

// Side mirrors reference.side.
type Side string

const (
	SideUnspecified Side = ""
	SideBuy         Side = "buy"
	SideSell        Side = "sell"
)

// Session mirrors the market.bar_1m.session column (pre | regular | post).
// "closed" never reaches the bar table; it exists so the aggregator can drop
// prints that arrive outside any session rather than mislabel them.
type Session string

const (
	SessionPre     Session = "pre"
	SessionRegular Session = "regular"
	SessionPost    Session = "post"
	SessionClosed  Session = "closed"
)

// Quality mirrors reference.data_quality.
type Quality string

const (
	QualityVerified  Quality = "verified"
	QualityVendor    Quality = "vendor"
	QualityDerived   Quality = "derived"
	QualityEstimated Quality = "estimated"
	QualitySuspect   Quality = "suspect"
)

// Feed names the logical stream, matching market.feed_health.feed.
type Feed string

const (
	FeedTrades Feed = "trades"
	FeedQuotes Feed = "quotes"
	FeedBars   Feed = "bars"
	FeedBook   Feed = "book"
)

// Trade is one print, mapping 1:1 onto market.trade.
type Trade struct {
	TS           time.Time
	InstrumentID uuid.UUID
	Symbol       string
	Price        decimal.Decimal
	Size         decimal.Decimal
	TradeID      string
	VenueID      int16
	Aggressor    Side
	Conditions   []string
	ExchangeTS   time.Time
	Quality      Quality
	Vendor       string
	Sequence     int64
}

// Quote is top of book, mapping onto market.quote. Spread and mid are GENERATED
// columns in Postgres and are recomputed here only for the gRPC surface.
type Quote struct {
	TS           time.Time
	InstrumentID uuid.UUID
	Symbol       string
	BidPrice     decimal.Decimal
	BidSize      decimal.Decimal
	AskPrice     decimal.Decimal
	AskSize      decimal.Decimal
	BidVenueID   int16
	AskVenueID   int16
	ExchangeTS   time.Time
	Vendor       string
	Sequence     int64
}

// Spread is ask-bid; zero when either side is missing.
func (q Quote) Spread() decimal.Decimal {
	if q.BidPrice.IsZero() || q.AskPrice.IsZero() {
		return decimal.Zero
	}
	return q.AskPrice.Sub(q.BidPrice)
}

// Mid is the arithmetic midpoint; zero when either side is missing.
func (q Quote) Mid() decimal.Decimal {
	if q.BidPrice.IsZero() || q.AskPrice.IsZero() {
		return decimal.Zero
	}
	return q.AskPrice.Add(q.BidPrice).Div(decimal.NewFromInt(2))
}

// Crossed reports a book where the ask sits below the bid. Real for a few
// microseconds across venues, almost always a defect from a single feed.
func (q Quote) Crossed() bool {
	if q.BidPrice.IsZero() || q.AskPrice.IsZero() {
		return false
	}
	return q.AskPrice.LessThan(q.BidPrice)
}

// Bar maps onto market.bar_1m. TS is the bucket OPEN time.
type Bar struct {
	TS           time.Time
	InstrumentID uuid.UUID
	Symbol       string
	Open         decimal.Decimal
	High         decimal.Decimal
	Low          decimal.Decimal
	Close        decimal.Decimal
	Volume       decimal.Decimal
	TradeCount   int32
	VWAP         decimal.Decimal
	Session      Session
	Quality      Quality
	Source       string
	Interval     time.Duration
	// Final is false while the bucket is still open. Streaming consumers must
	// not persist a non-final bar; the proto carries the same flag.
	Final bool
}

// BookLevel is one price level of an L2 book.
type BookLevel struct {
	Price      decimal.Decimal
	Size       decimal.Decimal
	OrderCount int32
}

// BookSnapshot maps onto market.book_snapshot. Bids descend, asks ascend.
type BookSnapshot struct {
	TS           time.Time
	InstrumentID uuid.UUID
	Symbol       string
	Sequence     int64
	Bids         []BookLevel
	Asks         []BookLevel
	DepthLevels  int16
	ImbalanceL1  decimal.Decimal
	ImbalanceL5  decimal.Decimal
}

// BookDelta is an incremental L2 update. A zero Size removes the level, which
// is the convention every venue in scope uses.
type BookDelta struct {
	TS           time.Time
	InstrumentID uuid.UUID
	Symbol       string
	Sequence     int64
	PrevSequence int64
	Snapshot     bool
	Bids         []BookLevel
	Asks         []BookLevel
	Vendor       string
}

// EventKind discriminates the Event union.
type EventKind uint8

// Event kinds.
const (
	KindTrade EventKind = iota + 1
	KindQuote
	KindBar
	KindBookDelta
)

// Event is the single channel type carried through the pipeline. A tagged union
// beats four parallel channels here: ordering between a trade and the quote
// that preceded it is meaningful, and separate channels would lose it.
type Event struct {
	Kind  EventKind
	Trade *Trade
	Quote *Quote
	Bar   *Bar
	Book  *BookDelta

	// Vendor and Feed are carried on the envelope so that metrics and health
	// accounting do not have to switch on Kind.
	Vendor string
	Feed   Feed
	// ReceivedAt is our own receipt time; ExchangeTS minus this is the feed
	// latency we alert on.
	ReceivedAt time.Time
}

// InstrumentID returns the instrument the event refers to.
func (e Event) InstrumentID() uuid.UUID {
	switch e.Kind {
	case KindTrade:
		return e.Trade.InstrumentID
	case KindQuote:
		return e.Quote.InstrumentID
	case KindBar:
		return e.Bar.InstrumentID
	case KindBookDelta:
		return e.Book.InstrumentID
	}
	return uuid.Nil
}

// ExchangeTS returns the venue timestamp when the vendor supplies one, falling
// back to our receipt time so latency maths never divides by a zero time.
func (e Event) ExchangeTS() time.Time {
	switch e.Kind {
	case KindTrade:
		if !e.Trade.ExchangeTS.IsZero() {
			return e.Trade.ExchangeTS
		}
		return e.Trade.TS
	case KindQuote:
		if !e.Quote.ExchangeTS.IsZero() {
			return e.Quote.ExchangeTS
		}
		return e.Quote.TS
	case KindBar:
		return e.Bar.TS
	case KindBookDelta:
		return e.Book.TS
	}
	return e.ReceivedAt
}
