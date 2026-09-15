// Package calendar answers "which trading session does this timestamp fall in?"
//
// The answer is a column: market.bar_1m.session is 'pre' | 'regular' | 'post',
// and most research explicitly excludes the extended sessions. Getting it wrong
// silently contaminates every backtest downstream, so the mapping is derived
// from reference.calendar_weekly_schedule and reference.calendar_exception
// rather than from a hardcoded 09:30.
package calendar

import (
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor/internal/model"
)

// DaySchedule is one weekday's session boundaries, in the calendar's timezone.
// A nil pre/post pair means the venue has no extended session that day.
type DaySchedule struct {
	PreMarketOpen   *time.Duration // since local midnight
	RegularOpen     time.Duration
	RegularClose    time.Duration
	PostMarketClose *time.Duration
}

// Exception overrides one date: a holiday (Closed) or a half day.
type Exception struct {
	Closed       bool
	RegularOpen  time.Duration
	RegularClose time.Duration
}

// Schedule is a whole calendar: reference.calendar plus its weekly schedule and
// its exceptions.
type Schedule struct {
	Code     string
	Location *time.Location
	// Weekly is indexed by time.Weekday (0 = Sunday), matching the
	// day_of_week CHECK in reference.calendar_weekly_schedule.
	Weekly [7]*DaySchedule
	// Exceptions is keyed by the local date in YYYY-MM-DD form.
	Exceptions map[string]Exception
	// AlwaysOpen short-circuits everything for 24x7 venues; a crypto venue has
	// no sessions and tagging its prints 'regular' is the correct answer.
	AlwaysOpen bool
}

// SessionAt classifies a timestamp.
func (s *Schedule) SessionAt(at time.Time) model.Session {
	if s == nil {
		return model.SessionRegular
	}
	if s.AlwaysOpen {
		return model.SessionRegular
	}
	loc := s.Location
	if loc == nil {
		loc = time.UTC
	}
	local := at.In(loc)
	day := time.Duration(local.Hour())*time.Hour +
		time.Duration(local.Minute())*time.Minute +
		time.Duration(local.Second())*time.Second +
		time.Duration(local.Nanosecond())

	sched := s.Weekly[int(local.Weekday())]
	if sched == nil {
		return model.SessionClosed
	}
	open, close := sched.RegularOpen, sched.RegularClose
	if ex, ok := s.Exceptions[local.Format("2006-01-02")]; ok {
		if ex.Closed {
			return model.SessionClosed
		}
		open, close = ex.RegularOpen, ex.RegularClose
	}

	switch {
	case day >= open && day < close:
		return model.SessionRegular
	case sched.PreMarketOpen != nil && day >= *sched.PreMarketOpen && day < open:
		return model.SessionPre
	// A half day shortens the regular close but not the post-market close, so
	// the post window is measured from the effective close, not the weekly one.
	case sched.PostMarketClose != nil && day >= close && day < *sched.PostMarketClose:
		return model.SessionPost
	}
	return model.SessionClosed
}

// Calendar resolves an instrument to its session at a point in time.
type Calendar interface {
	SessionFor(instrumentID uuid.UUID, at time.Time) model.Session
}

// Set is a Calendar backed by an instrument→schedule map. It is rebuilt
// wholesale by the reference-data loader rather than mutated in place, so the
// hot path never takes a write lock.
type Set struct {
	mu       sync.RWMutex
	byInst   map[uuid.UUID]*Schedule
	fallback *Schedule
}

// NewSet builds a Set with a fallback schedule used for unmapped instruments.
func NewSet(fallback *Schedule) *Set {
	return &Set{byInst: map[uuid.UUID]*Schedule{}, fallback: fallback}
}

// Replace swaps the instrument→schedule mapping atomically.
func (s *Set) Replace(byInst map[uuid.UUID]*Schedule) {
	s.mu.Lock()
	s.byInst = byInst
	s.mu.Unlock()
}

// SessionFor implements Calendar.
func (s *Set) SessionFor(instrumentID uuid.UUID, at time.Time) model.Session {
	s.mu.RLock()
	sched, ok := s.byInst[instrumentID]
	if !ok {
		sched = s.fallback
	}
	s.mu.RUnlock()
	return sched.SessionAt(at)
}

// AlwaysRegular is the degenerate calendar used when reference data has not
// loaded yet. It tags everything 'regular', which is wrong for extended hours
// but is the only choice that does not silently discard prints; the loader
// replaces it within seconds of startup.
type AlwaysRegular struct{}

// SessionFor implements Calendar.
func (AlwaysRegular) SessionFor(uuid.UUID, time.Time) model.Session { return model.SessionRegular }

func dur(h, m int) time.Duration {
	return time.Duration(h)*time.Hour + time.Duration(m)*time.Minute
}

// USEquities returns the NYSE/NASDAQ schedule: 04:00 pre, 09:30–16:00 regular,
// 20:00 post, New York time. Used as the fallback and as a test fixture.
func USEquities() *Schedule {
	loc, err := time.LoadLocation("America/New_York")
	if err != nil {
		// Containers without tzdata fall back to a fixed -05:00; that is wrong
		// for half the year, which is why the Dockerfile installs tzdata.
		loc = time.FixedZone("EST", -5*60*60)
	}
	pre := dur(4, 0)
	post := dur(20, 0)
	weekday := &DaySchedule{
		PreMarketOpen:   &pre,
		RegularOpen:     dur(9, 30),
		RegularClose:    dur(16, 0),
		PostMarketClose: &post,
	}
	s := &Schedule{Code: "NYSE", Location: loc, Exceptions: map[string]Exception{}}
	for d := time.Monday; d <= time.Friday; d++ {
		s.Weekly[int(d)] = weekday
	}
	return s
}

// Crypto24x7 is the always-open schedule used by crypto venues.
func Crypto24x7() *Schedule {
	return &Schedule{Code: "24x7", Location: time.UTC, AlwaysOpen: true, Exceptions: map[string]Exception{}}
}
