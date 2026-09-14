// Package clock abstracts wall-clock time so that every component whose
// behaviour is timing-dependent (backoff, circuit breakers, bar-bucket close)
// can be exercised deterministically. Tests must never call time.Sleep: a
// sleeping test is a slow test that is also flaky on a loaded CI box.
package clock

import (
	"container/heap"
	"context"
	"sync"
	"time"
)

// Ticker mirrors the useful surface of *time.Ticker.
type Ticker interface {
	C() <-chan time.Time
	Stop()
}

// Timer mirrors the useful surface of *time.Timer.
type Timer interface {
	C() <-chan time.Time
	Stop() bool
}

// Clock is the injection point. Production code takes a Clock; nothing in
// this repository calls time.Now() outside of Real.
type Clock interface {
	Now() time.Time
	NewTicker(d time.Duration) Ticker
	NewTimer(d time.Duration) Timer
	// Sleep returns ctx.Err() if the context is cancelled first, which makes
	// every backoff loop cancellable without an extra select at the call site.
	Sleep(ctx context.Context, d time.Duration) error
}

// ── real ─────────────────────────────────────────────────────────────────────

type realClock struct{}

// Real is the production clock.
func Real() Clock { return realClock{} }

func (realClock) Now() time.Time { return time.Now() }

type realTicker struct{ t *time.Ticker }

func (r realTicker) C() <-chan time.Time { return r.t.C }
func (r realTicker) Stop()               { r.t.Stop() }

func (realClock) NewTicker(d time.Duration) Ticker { return realTicker{time.NewTicker(d)} }

type realTimer struct{ t *time.Timer }

func (r realTimer) C() <-chan time.Time { return r.t.C }
func (r realTimer) Stop() bool          { return r.t.Stop() }

func (realClock) NewTimer(d time.Duration) Timer { return realTimer{time.NewTimer(d)} }

func (realClock) Sleep(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// ── fake ─────────────────────────────────────────────────────────────────────

type waiter struct {
	at     time.Time
	period time.Duration // 0 for one-shot timers
	ch     chan time.Time
	index  int
	dead   bool
}

type waiterHeap []*waiter

func (h waiterHeap) Len() int            { return len(h) }
func (h waiterHeap) Less(i, j int) bool  { return h[i].at.Before(h[j].at) }
func (h waiterHeap) Swap(i, j int)       { h[i], h[j] = h[j], h[i]; h[i].index = i; h[j].index = j }
func (h *waiterHeap) Push(x interface{}) { w := x.(*waiter); w.index = len(*h); *h = append(*h, w) }
func (h *waiterHeap) Pop() interface{} {
	old := *h
	n := len(old)
	w := old[n-1]
	old[n-1] = nil
	*h = old[:n-1]
	return w
}

// Fake is a manually advanced clock. Advance fires every ticker and timer whose
// deadline falls inside the advanced window, in chronological order, so a test
// that advances an hour sees sixty one-minute ticks rather than one.
type Fake struct {
	mu      sync.Mutex
	now     time.Time
	pending waiterHeap
}

// NewFake returns a Fake positioned at now.
func NewFake(now time.Time) *Fake {
	f := &Fake{now: now}
	heap.Init(&f.pending)
	return f
}

func (f *Fake) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

func (f *Fake) add(d time.Duration, period time.Duration) *waiter {
	f.mu.Lock()
	defer f.mu.Unlock()
	// Buffered by one and sent to non-blockingly, exactly like time.Ticker:
	// a slow consumer drops ticks instead of stalling the clock.
	w := &waiter{at: f.now.Add(d), period: period, ch: make(chan time.Time, 1)}
	heap.Push(&f.pending, w)
	return w
}

type fakeTicker struct {
	f *Fake
	w *waiter
}

func (t fakeTicker) C() <-chan time.Time { return t.w.ch }
func (t fakeTicker) Stop()               { t.f.kill(t.w) }

type fakeTimer struct {
	f *Fake
	w *waiter
}

func (t fakeTimer) C() <-chan time.Time { return t.w.ch }
func (t fakeTimer) Stop() bool          { return t.f.kill(t.w) }

func (f *Fake) kill(w *waiter) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	if w.dead {
		return false
	}
	w.dead = true
	if w.index >= 0 && w.index < len(f.pending) && f.pending[w.index] == w {
		heap.Remove(&f.pending, w.index)
	}
	return true
}

// NewTicker implements Clock.
func (f *Fake) NewTicker(d time.Duration) Ticker {
	if d <= 0 {
		panic("clock: non-positive interval for NewTicker")
	}
	return fakeTicker{f, f.add(d, d)}
}

// NewTimer implements Clock.
func (f *Fake) NewTimer(d time.Duration) Timer { return fakeTimer{f, f.add(d, 0)} }

// Sleep implements Clock.
func (f *Fake) Sleep(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := f.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C():
		return nil
	}
}

// Advance moves the clock forward, firing due waiters in time order.
func (f *Fake) Advance(d time.Duration) {
	f.mu.Lock()
	target := f.now.Add(d)
	for f.pending.Len() > 0 && !f.pending[0].at.After(target) {
		w := f.pending[0]
		f.now = w.at
		select {
		case w.ch <- w.at:
		default:
		}
		if w.period > 0 {
			w.at = w.at.Add(w.period)
			heap.Fix(&f.pending, 0)
		} else {
			heap.Pop(&f.pending)
			w.dead = true
		}
	}
	f.now = target
	f.mu.Unlock()
}

// Set jumps the clock to t. It panics on a backwards jump because every caller
// in this service assumes a monotonic clock.
func (f *Fake) Set(t time.Time) {
	f.mu.Lock()
	cur := f.now
	f.mu.Unlock()
	if t.Before(cur) {
		panic("clock: Fake.Set cannot move backwards")
	}
	f.Advance(t.Sub(cur))
}

// BlockUntilPending spins the scheduler until n waiters are registered. It is
// the one place a test needs to synchronise with a goroutine that is about to
// sleep; it yields rather than sleeping so it costs microseconds.
func (f *Fake) BlockUntilPending(n int) {
	for {
		f.mu.Lock()
		got := f.pending.Len()
		f.mu.Unlock()
		if got >= n {
			return
		}
		runtimeGosched()
	}
}
