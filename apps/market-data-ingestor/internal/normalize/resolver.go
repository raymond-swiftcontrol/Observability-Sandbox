package normalize

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/clock"
	"golang.org/x/sync/singleflight"
)

// ErrUnknownSymbol marks a vendor symbol with no row in
// reference.instrument_vendor_map.
var ErrUnknownSymbol = errors.New("normalize: unknown vendor symbol")

// SymbolStore reads reference.instrument_vendor_map. It is an interface so the
// normaliser can be tested without a database, and so a future implementation
// can serve the map from a compacted Kafka topic instead.
type SymbolStore interface {
	// LookupVendorSymbol returns the instrument uuid for (vendor, vendor_symbol).
	// A miss must return ErrUnknownSymbol, not a zero uuid and nil error.
	LookupVendorSymbol(ctx context.Context, vendor, vendorSymbol string) (uuid.UUID, error)
}

type resolveEntry struct {
	id      uuid.UUID
	found   bool
	expires time.Time
}

// ResolverMetrics receives cache outcome counts.
type ResolverMetrics interface {
	CacheOutcome(outcome string)
}

type nopResolverMetrics struct{}

func (nopResolverMetrics) CacheOutcome(string) {}

// Resolver maps vendor symbols onto instrument uuids.
//
// Two caches, not one. A positive hit is cached for TTL because the mapping
// changes about as often as a listing event. A *miss* is cached separately and
// far more briefly: a feed that is subscribed to a symbol we have no mapping
// for will send thousands of messages per second for it, and without negative
// caching every one of those becomes a database round trip — the fastest way
// to turn a reference-data omission into a database outage.
type Resolver struct {
	store   SymbolStore
	clk     clock.Clock
	ttl     time.Duration
	negTTL  time.Duration
	metrics ResolverMetrics

	mu    sync.RWMutex
	cache map[string]resolveEntry
	group singleflight.Group
}

// ResolverOptions configures a Resolver.
type ResolverOptions struct {
	TTL         time.Duration
	NegativeTTL time.Duration
	Clock       clock.Clock
	Metrics     ResolverMetrics
}

// NewResolver builds a Resolver over store.
func NewResolver(store SymbolStore, opts ResolverOptions) *Resolver {
	if opts.TTL <= 0 {
		opts.TTL = 10 * time.Minute
	}
	if opts.NegativeTTL <= 0 {
		opts.NegativeTTL = 30 * time.Second
	}
	if opts.Clock == nil {
		opts.Clock = clock.Real()
	}
	if opts.Metrics == nil {
		opts.Metrics = nopResolverMetrics{}
	}
	return &Resolver{
		store:   store,
		clk:     opts.Clock,
		ttl:     opts.TTL,
		negTTL:  opts.NegativeTTL,
		metrics: opts.Metrics,
		cache:   make(map[string]resolveEntry),
	}
}

func cacheKey(vendor, symbol string) string { return vendor + "\x00" + symbol }

// Resolve returns the instrument uuid for a vendor symbol, consulting the
// caches first. Concurrent misses for the same key collapse into one query.
func (r *Resolver) Resolve(ctx context.Context, vendor, symbol string) (uuid.UUID, error) {
	key := cacheKey(vendor, symbol)
	now := r.clk.Now()

	r.mu.RLock()
	e, ok := r.cache[key]
	r.mu.RUnlock()
	if ok && now.Before(e.expires) {
		if e.found {
			r.metrics.CacheOutcome("hit")
			return e.id, nil
		}
		r.metrics.CacheOutcome("negative_hit")
		return uuid.Nil, fmt.Errorf("%w: %s/%s", ErrUnknownSymbol, vendor, symbol)
	}

	r.metrics.CacheOutcome("miss")
	v, err, _ := r.group.Do(key, func() (any, error) {
		id, err := r.store.LookupVendorSymbol(ctx, vendor, symbol)
		exp := r.clk.Now()
		switch {
		case err == nil:
			r.store_(key, resolveEntry{id: id, found: true, expires: exp.Add(r.ttl)})
		case errors.Is(err, ErrUnknownSymbol):
			r.store_(key, resolveEntry{found: false, expires: exp.Add(r.negTTL)})
		default:
			// A transport failure is not evidence about the mapping, so it is
			// deliberately not cached either way.
			return uuid.Nil, err
		}
		return id, err
	})
	if err != nil {
		if errors.Is(err, ErrUnknownSymbol) {
			return uuid.Nil, fmt.Errorf("%w: %s/%s", ErrUnknownSymbol, vendor, symbol)
		}
		return uuid.Nil, fmt.Errorf("resolve %s/%s: %w", vendor, symbol, err)
	}
	return v.(uuid.UUID), nil
}

func (r *Resolver) store_(key string, e resolveEntry) {
	r.mu.Lock()
	r.cache[key] = e
	r.mu.Unlock()
}

// Invalidate drops one cached mapping. Called when a corporate action changes a
// ticker, so a rename does not wait out the TTL.
func (r *Resolver) Invalidate(vendor, symbol string) {
	r.mu.Lock()
	delete(r.cache, cacheKey(vendor, symbol))
	r.mu.Unlock()
}

// Len reports the number of cached entries, for the gauge and for tests.
func (r *Resolver) Len() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.cache)
}
