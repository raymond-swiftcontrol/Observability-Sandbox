-- Trading calendars. reference.trading_session rows are generated from these
-- by scripts/generate_sessions.py for a rolling window, so "is the market open
-- at t?" stays an index lookup rather than a computation on the hot path.
INSERT INTO reference.calendar (code, name, timezone) VALUES
  ('NYSE',  'NYSE / Nasdaq US Equities', 'America/New_York'),
  ('CME',   'CME Futures',               'America/Chicago'),
  ('OPRA',  'US Options',                'America/New_York'),
  ('LSE',   'London Stock Exchange',     'Europe/London'),
  ('XETR',  'Xetra',                     'Europe/Berlin'),
  ('TSE',   'Tokyo Stock Exchange',      'Asia/Tokyo'),
  ('24x7',  'Crypto (always open)',      'UTC')
ON CONFLICT (code) DO NOTHING;

-- US equities: 09:30-16:00 with pre-market from 04:00 and post to 20:00.
INSERT INTO reference.calendar_weekly_schedule
  (calendar_id, day_of_week, pre_market_open, regular_open, regular_close, post_market_close)
SELECT c.id, d, TIME '04:00', TIME '09:30', TIME '16:00', TIME '20:00'
  FROM reference.calendar c CROSS JOIN generate_series(1, 5) d
 WHERE c.code = 'NYSE'
ON CONFLICT DO NOTHING;

INSERT INTO reference.calendar_weekly_schedule
  (calendar_id, day_of_week, regular_open, regular_close)
SELECT c.id, d, TIME '09:30', TIME '16:15'
  FROM reference.calendar c CROSS JOIN generate_series(1, 5) d
 WHERE c.code = 'OPRA'
ON CONFLICT DO NOTHING;

INSERT INTO reference.calendar_weekly_schedule
  (calendar_id, day_of_week, regular_open, regular_close)
SELECT c.id, d, TIME '08:00', TIME '16:30'
  FROM reference.calendar c CROSS JOIN generate_series(1, 5) d
 WHERE c.code = 'LSE'
ON CONFLICT DO NOTHING;

INSERT INTO reference.calendar_weekly_schedule
  (calendar_id, day_of_week, regular_open, regular_close)
SELECT c.id, d, TIME '09:00', TIME '17:30'
  FROM reference.calendar c CROSS JOIN generate_series(1, 5) d
 WHERE c.code = 'XETR'
ON CONFLICT DO NOTHING;

-- Crypto never closes. Modelled as a full day every day rather than as a
-- special case, so the same "is it open?" query works for every venue.
INSERT INTO reference.calendar_weekly_schedule
  (calendar_id, day_of_week, regular_open, regular_close)
SELECT c.id, d, TIME '00:00', TIME '23:59:59'
  FROM reference.calendar c CROSS JOIN generate_series(0, 6) d
 WHERE c.code = '24x7'
ON CONFLICT DO NOTHING;

-- NYSE holidays and early closes. Half days matter: a backtest that assumes a
-- full session on the day after Thanksgiving mis-sizes every intraday position.
INSERT INTO reference.calendar_exception (calendar_id, exception_date, is_closed, label)
SELECT c.id, d::date, true, lbl
  FROM reference.calendar c,
       (VALUES
         ('2025-01-01','New Year''s Day'),   ('2025-01-20','MLK Day'),
         ('2025-02-17','Presidents'' Day'),  ('2025-04-18','Good Friday'),
         ('2025-05-26','Memorial Day'),      ('2025-06-19','Juneteenth'),
         ('2025-07-04','Independence Day'),  ('2025-09-01','Labor Day'),
         ('2025-11-27','Thanksgiving'),      ('2025-12-25','Christmas Day'),
         ('2026-01-01','New Year''s Day'),   ('2026-01-19','MLK Day'),
         ('2026-02-16','Presidents'' Day'),  ('2026-04-03','Good Friday'),
         ('2026-05-25','Memorial Day'),      ('2026-06-19','Juneteenth'),
         ('2026-07-03','Independence Day (observed)'), ('2026-09-07','Labor Day'),
         ('2026-11-26','Thanksgiving'),      ('2026-12-25','Christmas Day')
       ) AS h(d, lbl)
 WHERE c.code = 'NYSE'
ON CONFLICT DO NOTHING;

INSERT INTO reference.calendar_exception
  (calendar_id, exception_date, is_closed, regular_open, regular_close, label)
SELECT c.id, d::date, false, TIME '09:30', TIME '13:00', lbl
  FROM reference.calendar c,
       (VALUES
         ('2025-07-03','Day before Independence Day'),
         ('2025-11-28','Day after Thanksgiving'),
         ('2025-12-24','Christmas Eve'),
         ('2026-11-27','Day after Thanksgiving'),
         ('2026-12-24','Christmas Eve')
       ) AS h(d, lbl)
 WHERE c.code = 'NYSE'
ON CONFLICT DO NOTHING;
