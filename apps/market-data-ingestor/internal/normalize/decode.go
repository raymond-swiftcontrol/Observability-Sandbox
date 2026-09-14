package normalize

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/vendor"
	"github.com/shopspring/decimal"
)

// Decoder turns one vendor payload into zero or more canonical events with the
// instrument left unresolved (Symbol is set, InstrumentID is not).
//
// Decoders never touch the network or the database. That is what makes them
// table-testable against captured vendor bytes, which is the only honest way to
// keep up with a vendor changing its wire format.
type Decoder interface {
	Vendor() string
	Decode(m vendor.Message) ([]model.Event, error)
}

// DecodeError marks a payload that is structurally wrong for its vendor. It is
// deliberately distinct from a validation failure: a decode error means we do
// not understand the vendor, a validation failure means we understand it and
// disbelieve it. Both go to the DLQ, with different reasons.
type DecodeError struct {
	Vendor string
	Feed   model.Feed
	Reason string
	Err    error
}

func (e *DecodeError) Error() string {
	return fmt.Sprintf("decode %s/%s: %s: %v", e.Vendor, e.Feed, e.Reason, e.Err)
}
func (e *DecodeError) Unwrap() error { return e.Err }

func decodeFail(m vendor.Message, reason string, err error) error {
	return &DecodeError{Vendor: m.Vendor, Feed: m.Feed, Reason: reason, Err: err}
}

// VenueMapper resolves a vendor's exchange code to reference.venue.id. Venue
// ids are smallint in the schema and are the join key the execution model uses,
// so an unmapped code falls back to the vendor's default venue rather than
// silently writing zero.
type VenueMapper struct {
	byCode  map[string]int16
	fallbck int16
}

// NewVenueMapper builds a mapper with a fallback venue id.
func NewVenueMapper(byCode map[string]int16, fallback int16) VenueMapper {
	if byCode == nil {
		byCode = map[string]int16{}
	}
	return VenueMapper{byCode: byCode, fallbck: fallback}
}

// Venue returns the venue id for a vendor exchange code.
func (v VenueMapper) Venue(code string) int16 {
	if id, ok := v.byCode[code]; ok {
		return id
	}
	return v.fallbck
}

// ── sim ──────────────────────────────────────────────────────────────────────

// SimDecoder decodes the synthetic generator's wire format.
type SimDecoder struct{ Venues VenueMapper }

// Vendor implements Decoder.
func (SimDecoder) Vendor() string { return vendor.SimVendor }

type simEnvelope struct {
	Type   string `json:"t"`
	Symbol string `json:"s"`
	Ts     int64  `json:"ts"`
	Seq    int64  `json:"seq"`
}

type simQuoteWire struct {
	simEnvelope
	BidPrice decimal.Decimal `json:"bp"`
	BidSize  decimal.Decimal `json:"bs"`
	AskPrice decimal.Decimal `json:"ap"`
	AskSize  decimal.Decimal `json:"as"`
	BidVenue int16           `json:"bv"`
	AskVenue int16           `json:"av"`
}

type simTradeWire struct {
	simEnvelope
	Price   decimal.Decimal `json:"p"`
	Size    decimal.Decimal `json:"q"`
	TradeID string          `json:"i"`
	Venue   int16           `json:"v"`
	Side    string          `json:"sd"`
}

type simBookWire struct {
	simEnvelope
	Snapshot bool        `json:"snap"`
	Bids     [][2]string `json:"b"`
	Asks     [][2]string `json:"a"`
}

// Decode implements Decoder.
func (d SimDecoder) Decode(m vendor.Message) ([]model.Event, error) {
	var env simEnvelope
	if err := json.Unmarshal(m.Data, &env); err != nil {
		return nil, decodeFail(m, "envelope", err)
	}
	ts := time.Unix(0, env.Ts).UTC()
	switch env.Type {
	case "quote":
		var w simQuoteWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "quote body", err)
		}
		return []model.Event{wrap(m, model.KindQuote, &model.Quote{
			TS: ts, Symbol: w.Symbol, BidPrice: w.BidPrice, BidSize: w.BidSize,
			AskPrice: w.AskPrice, AskSize: w.AskSize,
			BidVenueID: w.BidVenue, AskVenueID: w.AskVenue,
			ExchangeTS: ts, Vendor: m.Vendor, Sequence: w.Seq,
		}, nil, nil, nil)}, nil
	case "trade":
		var w simTradeWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "trade body", err)
		}
		return []model.Event{wrap(m, model.KindTrade, nil, &model.Trade{
			TS: ts, Symbol: w.Symbol, Price: w.Price, Size: w.Size,
			TradeID: w.TradeID, VenueID: w.Venue, Aggressor: parseSide(w.Side),
			Conditions: []string{}, ExchangeTS: ts, Quality: model.QualityVendor,
			Vendor: m.Vendor, Sequence: w.Seq,
		}, nil, nil)}, nil
	case "book":
		var w simBookWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "book body", err)
		}
		bids, err := parseLevelPairs(w.Bids)
		if err != nil {
			return nil, decodeFail(m, "book bids", err)
		}
		asks, err := parseLevelPairs(w.Asks)
		if err != nil {
			return nil, decodeFail(m, "book asks", err)
		}
		return []model.Event{wrap(m, model.KindBookDelta, nil, nil, nil, &model.BookDelta{
			TS: ts, Symbol: w.Symbol, Sequence: w.Seq, Snapshot: w.Snapshot,
			Bids: bids, Asks: asks, Vendor: m.Vendor,
		})}, nil
	}
	return nil, decodeFail(m, "unknown message type "+env.Type, errUnsupported)
}

// ── polygon ──────────────────────────────────────────────────────────────────

// PolygonDecoder decodes Polygon.io stocks cluster events.
type PolygonDecoder struct{ Venues VenueMapper }

// Vendor implements Decoder.
func (PolygonDecoder) Vendor() string { return vendor.PolygonVendor }

type polygonTradeWire struct {
	Event      string          `json:"ev"`
	Symbol     string          `json:"sym"`
	TradeID    string          `json:"i"`
	Exchange   int16           `json:"x"`
	Price      decimal.Decimal `json:"p"`
	Size       decimal.Decimal `json:"s"`
	Conditions []int           `json:"c"`
	TsMillis   int64           `json:"t"`
	Sequence   int64           `json:"q"`
}

type polygonQuoteWire struct {
	Event    string          `json:"ev"`
	Symbol   string          `json:"sym"`
	BidExch  int16           `json:"bx"`
	BidPrice decimal.Decimal `json:"bp"`
	BidSize  decimal.Decimal `json:"bs"`
	AskExch  int16           `json:"ax"`
	AskPrice decimal.Decimal `json:"ap"`
	AskSize  decimal.Decimal `json:"as"`
	TsMillis int64           `json:"t"`
	Sequence int64           `json:"q"`
}

type polygonBarWire struct {
	Event    string          `json:"ev"`
	Symbol   string          `json:"sym"`
	Open     decimal.Decimal `json:"o"`
	High     decimal.Decimal `json:"h"`
	Low      decimal.Decimal `json:"l"`
	Close    decimal.Decimal `json:"c"`
	Volume   decimal.Decimal `json:"v"`
	VWAP     decimal.Decimal `json:"vw"`
	StartMs  int64           `json:"s"`
	EndMs    int64           `json:"e"`
	AvgTrade decimal.Decimal `json:"a"`
}

// Decode implements Decoder.
func (d PolygonDecoder) Decode(m vendor.Message) ([]model.Event, error) {
	var probe struct {
		Event string `json:"ev"`
	}
	if err := json.Unmarshal(m.Data, &probe); err != nil {
		return nil, decodeFail(m, "envelope", err)
	}
	switch probe.Event {
	case "T":
		var w polygonTradeWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "trade body", err)
		}
		ts := time.UnixMilli(w.TsMillis).UTC()
		return []model.Event{wrap(m, model.KindTrade, nil, &model.Trade{
			TS: ts, Symbol: w.Symbol, Price: w.Price, Size: w.Size,
			TradeID: w.TradeID, VenueID: d.Venues.Venue(itoa16(w.Exchange)),
			// Polygon does not tag the aggressor on the equities tape; leaving
			// it unspecified is honest, inferring it from the quote is not.
			Aggressor: model.SideUnspecified,
			// Condition codes are numeric on the wire and varchar(8)[] in the
			// schema, so they are rendered rather than mapped to venue words.
			Conditions: intsToStrings(w.Conditions),
			ExchangeTS: ts, Quality: model.QualityVendor,
			Vendor: m.Vendor, Sequence: w.Sequence,
		}, nil, nil)}, nil
	case "Q":
		var w polygonQuoteWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "quote body", err)
		}
		ts := time.UnixMilli(w.TsMillis).UTC()
		return []model.Event{wrap(m, model.KindQuote, &model.Quote{
			TS: ts, Symbol: w.Symbol,
			BidPrice: w.BidPrice, BidSize: w.BidSize,
			AskPrice: w.AskPrice, AskSize: w.AskSize,
			BidVenueID: d.Venues.Venue(itoa16(w.BidExch)),
			AskVenueID: d.Venues.Venue(itoa16(w.AskExch)),
			ExchangeTS: ts, Vendor: m.Vendor, Sequence: w.Sequence,
		}, nil, nil, nil)}, nil
	case "AM", "A":
		var w polygonBarWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "bar body", err)
		}
		return []model.Event{wrap(m, model.KindBar, nil, nil, &model.Bar{
			TS: time.UnixMilli(w.StartMs).UTC(), Symbol: w.Symbol,
			Open: w.Open, High: w.High, Low: w.Low, Close: w.Close,
			Volume: w.Volume, VWAP: w.VWAP,
			Quality: model.QualityVendor, Source: vendor.PolygonVendor,
			Interval: time.Duration(w.EndMs-w.StartMs) * time.Millisecond,
			Final:    true,
		}, nil)}, nil
	}
	return nil, decodeFail(m, "unsupported event "+probe.Event, errUnsupported)
}

// ── alpaca ───────────────────────────────────────────────────────────────────

// AlpacaDecoder decodes Alpaca market data v2 events.
type AlpacaDecoder struct{ Venues VenueMapper }

// Vendor implements Decoder.
func (AlpacaDecoder) Vendor() string { return vendor.AlpacaVendor }

type alpacaTradeWire struct {
	Type       string          `json:"T"`
	Symbol     string          `json:"S"`
	TradeID    int64           `json:"i"`
	Exchange   string          `json:"x"`
	Price      decimal.Decimal `json:"p"`
	Size       decimal.Decimal `json:"s"`
	Conditions []string        `json:"c"`
	Tape       string          `json:"z"`
	Timestamp  time.Time       `json:"t"`
}

type alpacaQuoteWire struct {
	Type     string          `json:"T"`
	Symbol   string          `json:"S"`
	BidExch  string          `json:"bx"`
	BidPrice decimal.Decimal `json:"bp"`
	BidSize  decimal.Decimal `json:"bs"`
	AskExch  string          `json:"ax"`
	AskPrice decimal.Decimal `json:"ap"`
	AskSize  decimal.Decimal `json:"as"`
	Ts       time.Time       `json:"t"`
}

type alpacaBarWire struct {
	Type       string          `json:"T"`
	Symbol     string          `json:"S"`
	Open       decimal.Decimal `json:"o"`
	High       decimal.Decimal `json:"h"`
	Low        decimal.Decimal `json:"l"`
	Close      decimal.Decimal `json:"c"`
	Volume     decimal.Decimal `json:"v"`
	VWAP       decimal.Decimal `json:"vw"`
	TradeCount int32           `json:"n"`
	Ts         time.Time       `json:"t"`
}

// Decode implements Decoder.
func (d AlpacaDecoder) Decode(m vendor.Message) ([]model.Event, error) {
	var probe struct {
		Type string `json:"T"`
	}
	if err := json.Unmarshal(m.Data, &probe); err != nil {
		return nil, decodeFail(m, "envelope", err)
	}
	switch probe.Type {
	case "t":
		var w alpacaTradeWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "trade body", err)
		}
		return []model.Event{wrap(m, model.KindTrade, nil, &model.Trade{
			TS: w.Timestamp.UTC(), Symbol: w.Symbol, Price: w.Price, Size: w.Size,
			TradeID: itoa64(w.TradeID), VenueID: d.Venues.Venue(w.Exchange),
			Aggressor: model.SideUnspecified, Conditions: w.Conditions,
			ExchangeTS: w.Timestamp.UTC(), Quality: model.QualityVendor,
			Vendor: m.Vendor, Sequence: w.TradeID,
		}, nil, nil)}, nil
	case "q":
		var w alpacaQuoteWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "quote body", err)
		}
		return []model.Event{wrap(m, model.KindQuote, &model.Quote{
			TS: w.Ts.UTC(), Symbol: w.Symbol,
			BidPrice: w.BidPrice, BidSize: w.BidSize,
			AskPrice: w.AskPrice, AskSize: w.AskSize,
			BidVenueID: d.Venues.Venue(w.BidExch), AskVenueID: d.Venues.Venue(w.AskExch),
			ExchangeTS: w.Ts.UTC(), Vendor: m.Vendor, Sequence: vendor.SequenceUnknown,
		}, nil, nil, nil)}, nil
	case "b", "d", "u":
		var w alpacaBarWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "bar body", err)
		}
		return []model.Event{wrap(m, model.KindBar, nil, nil, &model.Bar{
			TS: w.Ts.UTC(), Symbol: w.Symbol,
			Open: w.Open, High: w.High, Low: w.Low, Close: w.Close,
			Volume: w.Volume, VWAP: w.VWAP, TradeCount: w.TradeCount,
			Quality: model.QualityVendor, Source: vendor.AlpacaVendor,
			Interval: time.Minute, Final: true,
		}, nil)}, nil
	}
	return nil, decodeFail(m, "unsupported type "+probe.Type, errUnsupported)
}

// ── binance ──────────────────────────────────────────────────────────────────

// BinanceDecoder decodes Binance combined-stream payloads.
type BinanceDecoder struct {
	Venues VenueMapper
	// VenueID is the reference.venue.id for the Binance CEX; every Binance
	// print comes from the same venue, so there is no per-message mapping.
	VenueID int16
}

// Vendor implements Decoder.
func (BinanceDecoder) Vendor() string { return vendor.BinanceVendor }

type binanceTradeWire struct {
	Event    string          `json:"e"`
	EventMs  int64           `json:"E"`
	Symbol   string          `json:"s"`
	TradeID  int64           `json:"t"`
	Price    decimal.Decimal `json:"p"`
	Quantity decimal.Decimal `json:"q"`
	TradeMs  int64           `json:"T"`
	// BuyerIsMaker true means the aggressor was the seller.
	BuyerIsMaker bool `json:"m"`
}

type binanceBookTickerWire struct {
	UpdateID int64           `json:"u"`
	Symbol   string          `json:"s"`
	BidPrice decimal.Decimal `json:"b"`
	BidQty   decimal.Decimal `json:"B"`
	AskPrice decimal.Decimal `json:"a"`
	AskQty   decimal.Decimal `json:"A"`
}

type binanceDepthWire struct {
	Event       string      `json:"e"`
	EventMs     int64       `json:"E"`
	Symbol      string      `json:"s"`
	FirstUpdate int64       `json:"U"`
	FinalUpdate int64       `json:"u"`
	Bids        [][2]string `json:"b"`
	Asks        [][2]string `json:"a"`
}

// Decode implements Decoder. Binance's streams have no shared discriminator, so
// the feed the transport tagged the message with selects the shape.
func (d BinanceDecoder) Decode(m vendor.Message) ([]model.Event, error) {
	switch m.Feed {
	case model.FeedTrades:
		var w binanceTradeWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "trade body", err)
		}
		agg := model.SideBuy
		if w.BuyerIsMaker {
			agg = model.SideSell
		}
		ts := time.UnixMilli(w.TradeMs).UTC()
		return []model.Event{wrap(m, model.KindTrade, nil, &model.Trade{
			TS: ts, Symbol: w.Symbol, Price: w.Price, Size: w.Quantity,
			TradeID: itoa64(w.TradeID), VenueID: d.VenueID, Aggressor: agg,
			Conditions: []string{}, ExchangeTS: ts, Quality: model.QualityVendor,
			Vendor: m.Vendor, Sequence: w.TradeID,
		}, nil, nil)}, nil
	case model.FeedQuotes:
		var w binanceBookTickerWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "bookTicker body", err)
		}
		// bookTicker carries no timestamp; receipt time is the best available
		// and is flagged as such by leaving ExchangeTS zero.
		return []model.Event{wrap(m, model.KindQuote, &model.Quote{
			TS: m.ReceivedAt.UTC(), Symbol: w.Symbol,
			BidPrice: w.BidPrice, BidSize: w.BidQty,
			AskPrice: w.AskPrice, AskSize: w.AskQty,
			BidVenueID: d.VenueID, AskVenueID: d.VenueID,
			Vendor: m.Vendor, Sequence: w.UpdateID,
		}, nil, nil, nil)}, nil
	case model.FeedBook:
		var w binanceDepthWire
		if err := json.Unmarshal(m.Data, &w); err != nil {
			return nil, decodeFail(m, "depth body", err)
		}
		bids, err := parseLevelPairs(w.Bids)
		if err != nil {
			return nil, decodeFail(m, "depth bids", err)
		}
		asks, err := parseLevelPairs(w.Asks)
		if err != nil {
			return nil, decodeFail(m, "depth asks", err)
		}
		return []model.Event{wrap(m, model.KindBookDelta, nil, nil, nil, &model.BookDelta{
			TS: time.UnixMilli(w.EventMs).UTC(), Symbol: w.Symbol,
			Sequence: w.FinalUpdate, PrevSequence: w.FirstUpdate - 1,
			Bids: bids, Asks: asks, Vendor: m.Vendor,
		})}, nil
	}
	return nil, decodeFail(m, "unsupported feed "+string(m.Feed), errUnsupported)
}

// ── shared helpers ───────────────────────────────────────────────────────────

var errUnsupported = fmt.Errorf("unsupported payload")

func wrap(m vendor.Message, kind model.EventKind, q *model.Quote, t *model.Trade, b *model.Bar, d *model.BookDelta) model.Event {
	return model.Event{
		Kind: kind, Quote: q, Trade: t, Bar: b, Book: d,
		Vendor: m.Vendor, Feed: m.Feed, ReceivedAt: m.ReceivedAt,
	}
}

func parseLevelPairs(in [][2]string) ([]model.BookLevel, error) {
	out := make([]model.BookLevel, 0, len(in))
	for i, pair := range in {
		px, err := decimal.NewFromString(pair[0])
		if err != nil {
			return nil, fmt.Errorf("level %d price %q: %w", i, pair[0], err)
		}
		sz, err := decimal.NewFromString(pair[1])
		if err != nil {
			return nil, fmt.Errorf("level %d size %q: %w", i, pair[1], err)
		}
		out = append(out, model.BookLevel{Price: px, Size: sz})
	}
	return out, nil
}

func parseSide(s string) model.Side {
	switch strings.ToLower(s) {
	case "buy", "b":
		return model.SideBuy
	case "sell", "s":
		return model.SideSell
	}
	return model.SideUnspecified
}

func intsToStrings(in []int) []string {
	out := make([]string, 0, len(in))
	for _, v := range in {
		out = append(out, itoa64(int64(v)))
	}
	return out
}

func itoa64(v int64) string { return decimal.NewFromInt(v).String() }
func itoa16(v int16) string { return decimal.NewFromInt(int64(v)).String() }
