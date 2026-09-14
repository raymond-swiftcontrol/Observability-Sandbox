// Package normalize turns vendor payloads into canonical model events.
//
// It is the only place in the ingestor that decides a message is untrustworthy,
// and the rule it follows comes from the schema itself: db/migrations/0004
// comments on market.quote's quote_not_crossed constraint say the ingestor
// "routes violations to the DLQ rather than dropping them". Dropping a bad tick
// destroys the evidence needed to tell a vendor defect from our own bug, so
// every rejection is published with its original bytes and a machine-readable
// reason.
package normalize

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/clock"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/vendor"
)

// Rejection reasons. These are a closed vocabulary because they become a
// metric label and a DLQ field that alerts key off.
const (
	ReasonDecode         = "decode_error"
	ReasonUnknownSymbol  = "unknown_symbol"
	ReasonResolverError  = "resolver_error"
	ReasonNonPositivePx  = "non_positive_price"
	ReasonNonPositiveQty = "non_positive_size"
	ReasonCrossedBook    = "crossed_book"
	ReasonOutOfOrder     = "out_of_order_timestamp"
	ReasonFutureTS       = "timestamp_in_future"
	ReasonMissingTS      = "missing_timestamp"
	ReasonIncoherentOHLC = "incoherent_ohlc"
	ReasonNoDecoder      = "no_decoder"
)

// Reject is one rejected message, published verbatim to the DLQ topic.
type Reject struct {
	Vendor     string     `json:"vendor"`
	Feed       model.Feed `json:"feed"`
	Symbol     string     `json:"symbol"`
	Reason     string     `json:"reason"`
	Detail     string     `json:"detail"`
	ReceivedAt time.Time  `json:"received_at"`
	RejectedAt time.Time  `json:"rejected_at"`
	// Payload is the untouched vendor bytes. Re-encoding it would lose exactly
	// the malformation we are trying to capture.
	Payload []byte `json:"payload"`
	TraceID string `json:"trace_id,omitempty"`
}

// DLQ publishes rejected messages.
type DLQ interface {
	PublishReject(ctx context.Context, r Reject) error
}

// Metrics receives normalisation counters.
type Metrics interface {
	Reject(reason string)
	DLQPublished()
	CacheOutcome(outcome string)
}

type nopMetrics struct{}

func (nopMetrics) Reject(string)       {}
func (nopMetrics) DLQPublished()       {}
func (nopMetrics) CacheOutcome(string) {}

// Options configures a Normalizer.
type Options struct {
	Clock   clock.Clock
	Logger  *slog.Logger
	DLQ     DLQ
	Metrics Metrics
	// OutOfOrderTolerance is how far behind the last seen timestamp for an
	// instrument+feed a message may be before it is rejected. Feeds legitimately
	// interleave a few milliseconds out of order across venue partitions; a
	// message minutes behind is a replay or a clock fault.
	OutOfOrderTolerance time.Duration
	// FutureTolerance bounds clock skew on the vendor side.
	FutureTolerance time.Duration
}

// Normalizer decodes, resolves and validates.
type Normalizer struct {
	decoders map[string]Decoder
	resolver *Resolver
	opts     Options

	mu       sync.Mutex
	lastSeen map[tsKey]time.Time
}

type tsKey struct {
	id   uuid.UUID
	feed model.Feed
}

// New builds a Normalizer over the supplied decoders.
func New(resolver *Resolver, decoders []Decoder, opts Options) *Normalizer {
	if opts.Clock == nil {
		opts.Clock = clock.Real()
	}
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	if opts.Metrics == nil {
		opts.Metrics = nopMetrics{}
	}
	if opts.OutOfOrderTolerance <= 0 {
		opts.OutOfOrderTolerance = 5 * time.Second
	}
	if opts.FutureTolerance <= 0 {
		opts.FutureTolerance = 2 * time.Second
	}
	m := map[string]Decoder{}
	for _, d := range decoders {
		m[d.Vendor()] = d
	}
	return &Normalizer{decoders: m, resolver: resolver, opts: opts, lastSeen: map[tsKey]time.Time{}}
}

// Process decodes one vendor message into canonical events. Rejected messages
// are routed to the DLQ and reported through the returned Rejects slice; they
// are never an error, because one bad tick must not stop the stream.
func (n *Normalizer) Process(ctx context.Context, m vendor.Message) ([]model.Event, []Reject) {
	dec, ok := n.decoders[m.Vendor]
	if !ok {
		return nil, []Reject{n.reject(ctx, m, ReasonNoDecoder, "no decoder registered for vendor "+m.Vendor)}
	}
	events, err := dec.Decode(m)
	if err != nil {
		return nil, []Reject{n.reject(ctx, m, ReasonDecode, err.Error())}
	}

	out := make([]model.Event, 0, len(events))
	var rejects []Reject
	for _, ev := range events {
		symbol := eventSymbol(ev)
		id, err := n.resolver.Resolve(ctx, m.Vendor, symbol)
		if err != nil {
			reason := ReasonResolverError
			if errors.Is(err, ErrUnknownSymbol) {
				reason = ReasonUnknownSymbol
			}
			rejects = append(rejects, n.reject(ctx, m, reason, err.Error()))
			continue
		}
		setInstrumentID(&ev, id)

		if reason, detail := n.validate(&ev); reason != "" {
			rejects = append(rejects, n.reject(ctx, m, reason, detail))
			continue
		}
		n.recordTimestamp(ev)
		out = append(out, ev)
	}
	return out, rejects
}

// validate applies the invariants the SQL CHECK constraints would otherwise
// enforce at write time. Catching them here keeps a bad batch from failing a
// whole CopyFrom, which would take good rows down with it.
func (n *Normalizer) validate(ev *model.Event) (reason, detail string) {
	switch ev.Kind {
	case model.KindTrade:
		t := ev.Trade
		if t.TS.IsZero() {
			return ReasonMissingTS, "trade has no timestamp"
		}
		if !t.Price.IsPositive() {
			return ReasonNonPositivePx, fmt.Sprintf("price %s violates market.trade.trade_price_positive", t.Price)
		}
		if !t.Size.IsPositive() {
			return ReasonNonPositiveQty, fmt.Sprintf("size %s violates market.trade.trade_size_positive", t.Size)
		}
		return n.checkTime(ev, t.TS)

	case model.KindQuote:
		q := ev.Quote
		if q.TS.IsZero() {
			return ReasonMissingTS, "quote has no timestamp"
		}
		if q.BidPrice.IsNegative() || q.AskPrice.IsNegative() {
			return ReasonNonPositivePx, fmt.Sprintf("negative quote prices bid=%s ask=%s", q.BidPrice, q.AskPrice)
		}
		if q.Crossed() {
			return ReasonCrossedBook, fmt.Sprintf("ask %s below bid %s violates market.quote.quote_not_crossed", q.AskPrice, q.BidPrice)
		}
		return n.checkTime(ev, q.TS)

	case model.KindBar:
		b := ev.Bar
		if b.TS.IsZero() {
			return ReasonMissingTS, "bar has no timestamp"
		}
		if !b.Open.IsPositive() || !b.High.IsPositive() || !b.Low.IsPositive() || !b.Close.IsPositive() {
			return ReasonNonPositivePx, fmt.Sprintf("non-positive OHLC o=%s h=%s l=%s c=%s", b.Open, b.High, b.Low, b.Close)
		}
		if b.High.LessThan(b.Low) || b.High.LessThan(b.Open) || b.High.LessThan(b.Close) ||
			b.Low.GreaterThan(b.Open) || b.Low.GreaterThan(b.Close) {
			return ReasonIncoherentOHLC, fmt.Sprintf("violates market.bar_1m.bar_1m_ohlc_coherent o=%s h=%s l=%s c=%s", b.Open, b.High, b.Low, b.Close)
		}
		return n.checkTime(ev, b.TS)

	case model.KindBookDelta:
		d := ev.Book
		if d.TS.IsZero() {
			return ReasonMissingTS, "book delta has no timestamp"
		}
		for _, lv := range append(append([]model.BookLevel{}, d.Bids...), d.Asks...) {
			if lv.Price.IsNegative() {
				return ReasonNonPositivePx, fmt.Sprintf("negative book level price %s", lv.Price)
			}
			if lv.Size.IsNegative() {
				return ReasonNonPositiveQty, fmt.Sprintf("negative book level size %s", lv.Size)
			}
		}
		// A snapshot whose best bid exceeds its best ask is a crossed book and
		// is rejected the same way a crossed quote is. Increments are not
		// checked here; the book manager applies them and validates the result,
		// because an increment is only meaningful against its base.
		if d.Snapshot && len(d.Bids) > 0 && len(d.Asks) > 0 {
			if d.Asks[0].Price.LessThan(d.Bids[0].Price) && d.Asks[0].Price.IsPositive() {
				return ReasonCrossedBook, fmt.Sprintf("snapshot crossed: best ask %s below best bid %s", d.Asks[0].Price, d.Bids[0].Price)
			}
		}
		return n.checkTime(ev, d.TS)
	}
	return "", ""
}

func (n *Normalizer) checkTime(ev *model.Event, ts time.Time) (reason, detail string) {
	now := n.opts.Clock.Now()
	if ts.After(now.Add(n.opts.FutureTolerance)) {
		return ReasonFutureTS, fmt.Sprintf("timestamp %s is %s ahead of now", ts.UTC().Format(time.RFC3339Nano), ts.Sub(now))
	}
	k := tsKey{id: ev.InstrumentID(), feed: ev.Feed}
	n.mu.Lock()
	last, seen := n.lastSeen[k]
	n.mu.Unlock()
	if seen && ts.Before(last.Add(-n.opts.OutOfOrderTolerance)) {
		return ReasonOutOfOrder, fmt.Sprintf("timestamp %s is %s behind the last seen %s (tolerance %s)",
			ts.UTC().Format(time.RFC3339Nano), last.Sub(ts), last.UTC().Format(time.RFC3339Nano), n.opts.OutOfOrderTolerance)
	}
	return "", ""
}

func (n *Normalizer) recordTimestamp(ev model.Event) {
	k := tsKey{id: ev.InstrumentID(), feed: ev.Feed}
	ts := ev.ExchangeTS()
	n.mu.Lock()
	if last, ok := n.lastSeen[k]; !ok || ts.After(last) {
		n.lastSeen[k] = ts
	}
	n.mu.Unlock()
}

func (n *Normalizer) reject(ctx context.Context, m vendor.Message, reason, detail string) Reject {
	r := Reject{
		Vendor: m.Vendor, Feed: m.Feed, Symbol: m.Symbol,
		Reason: reason, Detail: detail,
		ReceivedAt: m.ReceivedAt, RejectedAt: n.opts.Clock.Now(),
		Payload: m.Data,
	}
	n.opts.Metrics.Reject(reason)
	if n.opts.DLQ != nil {
		if err := n.opts.DLQ.PublishReject(ctx, r); err != nil {
			// A DLQ we cannot write to is itself an incident: log loudly, but
			// keep processing. Blocking the pipeline on the DLQ would let one
			// broken topic stop all ingestion.
			n.opts.Logger.ErrorContext(ctx, "failed to publish rejection to DLQ",
				slog.String("vendor", m.Vendor), slog.String("reason", reason), slog.Any("error", err))
		} else {
			n.opts.Metrics.DLQPublished()
		}
	}
	return r
}

func eventSymbol(ev model.Event) string {
	switch ev.Kind {
	case model.KindTrade:
		return ev.Trade.Symbol
	case model.KindQuote:
		return ev.Quote.Symbol
	case model.KindBar:
		return ev.Bar.Symbol
	case model.KindBookDelta:
		return ev.Book.Symbol
	}
	return ""
}

func setInstrumentID(ev *model.Event, id uuid.UUID) {
	switch ev.Kind {
	case model.KindTrade:
		ev.Trade.InstrumentID = id
	case model.KindQuote:
		ev.Quote.InstrumentID = id
	case model.KindBar:
		ev.Bar.InstrumentID = id
	case model.KindBookDelta:
		ev.Book.InstrumentID = id
	}
}
