-- A small, real universe so the app has something to show on first run.
-- Liquidity figures are indicative and only need to be the right order of
-- magnitude: they feed universe selection and the slippage model's
-- participation cap, both of which are relative.
WITH v AS (SELECT code, id FROM reference.venue),
     c AS (SELECT code, id FROM reference.calendar),
     s AS (SELECT gics_code, id FROM reference.sector)
INSERT INTO reference.instrument
  (symbol, venue_id, asset_class, name, currency, calendar_id, sector_id,
   country_code, tick_size, is_shortable, is_marginable, is_fractionable,
   adv_30d, median_spread_bps, market_cap, listed_on, data_start_date)
SELECT d.symbol,
       (SELECT id FROM v WHERE v.code = d.venue),
       d.asset_class::reference.asset_class,
       d.name, 'USD',
       (SELECT id FROM c WHERE c.code = d.calendar),
       (SELECT id FROM s WHERE s.gics_code = d.gics),
       'US', 0.01, true, true, true,
       d.adv, d.spread_bps, d.mcap, d.listed::date, d.listed::date
  FROM (VALUES
    ('AAPL','XNAS','equity','Apple Inc.','NYSE','45',        55000000, 1.0, 3400000000000.0, '1980-12-12'),
    ('MSFT','XNAS','equity','Microsoft Corporation','NYSE','45', 22000000, 1.1, 3100000000000.0, '1986-03-13'),
    ('NVDA','XNAS','equity','NVIDIA Corporation','NYSE','45',   240000000, 1.2, 3000000000000.0, '1999-01-22'),
    ('AMZN','XNAS','equity','Amazon.com Inc.','NYSE','25',       40000000, 1.3, 1900000000000.0, '1997-05-15'),
    ('GOOGL','XNAS','equity','Alphabet Inc. Class A','NYSE','50',28000000, 1.2, 2100000000000.0, '2004-08-19'),
    ('META','XNAS','equity','Meta Platforms Inc.','NYSE','50',   15000000, 1.4, 1300000000000.0, '2012-05-18'),
    ('TSLA','XNAS','equity','Tesla Inc.','NYSE','25',           95000000, 1.8,  800000000000.0, '2010-06-29'),
    ('BRK.B','XNYS','equity','Berkshire Hathaway Class B','NYSE','40', 4000000, 1.6, 900000000000.0, '1996-05-09'),
    ('JPM','XNYS','equity','JPMorgan Chase & Co.','NYSE','40',    9000000, 1.5,  650000000000.0, '1969-03-05'),
    ('V','XNYS','equity','Visa Inc.','NYSE','45',                 6000000, 1.5,  560000000000.0, '2008-03-19'),
    ('JNJ','XNYS','equity','Johnson & Johnson','NYSE','35',       7000000, 1.6,  380000000000.0, '1944-09-24'),
    ('XOM','XNYS','equity','Exxon Mobil Corporation','NYSE','10',16000000, 1.7,  480000000000.0, '1972-01-03'),
    ('WMT','XNYS','equity','Walmart Inc.','NYSE','30',           18000000, 1.5,  700000000000.0, '1972-08-25'),
    ('PG','XNYS','equity','Procter & Gamble','NYSE','30',         7000000, 1.6,  390000000000.0, '1950-01-03'),
    ('UNH','XNYS','equity','UnitedHealth Group','NYSE','35',      3500000, 2.0,  520000000000.0, '1984-10-17'),
    ('HD','XNYS','equity','The Home Depot','NYSE','25',           3400000, 1.9,  390000000000.0, '1981-09-22'),
    ('AMD','XNAS','equity','Advanced Micro Devices','NYSE','45', 45000000, 1.4,  240000000000.0, '1979-09-27'),
    ('INTC','XNAS','equity','Intel Corporation','NYSE','45',     60000000, 1.6,   95000000000.0, '1971-10-13'),
    ('GME','XNYS','equity','GameStop Corp.','NYSE','25',         12000000, 8.0,   10000000000.0, '2002-02-13'),
    ('PLTR','XNAS','equity','Palantir Technologies','NYSE','45', 55000000, 2.5,  180000000000.0, '2020-09-30'),
    ('SPY','ARCX','etf','SPDR S&P 500 ETF Trust','NYSE',NULL,    75000000, 0.5,  600000000000.0, '1993-01-22'),
    ('QQQ','XNAS','etf','Invesco QQQ Trust','NYSE',NULL,         45000000, 0.6,  300000000000.0, '1999-03-10'),
    ('IWM','ARCX','etf','iShares Russell 2000 ETF','NYSE',NULL,  30000000, 0.9,   65000000000.0, '2000-05-22'),
    ('TLT','XNAS','etf','iShares 20+ Year Treasury Bond','NYSE',NULL, 35000000, 1.0, 50000000000.0, '2002-07-22'),
    ('GLD','ARCX','etf','SPDR Gold Shares','NYSE',NULL,           8000000, 1.0,   75000000000.0, '2004-11-18'),
    ('HYG','ARCX','etf','iShares iBoxx High Yield Corporate','NYSE',NULL, 45000000, 1.2, 17000000000.0, '2007-04-04'),
    ('XLF','ARCX','etf','Financial Select Sector SPDR','NYSE',NULL, 40000000, 1.0, 45000000000.0, '1998-12-16'),
    ('XLE','ARCX','etf','Energy Select Sector SPDR','NYSE',NULL,  18000000, 1.1,  35000000000.0, '1998-12-16'),
    ('VXX','BATS','etf','iPath Series B S&P 500 VIX Short-Term','NYSE',NULL, 25000000, 4.0, 400000000.0, '2018-01-17')
  ) AS d(symbol, venue, asset_class, name, calendar, gics, adv, spread_bps, mcap, listed)
ON CONFLICT DO NOTHING;

-- Index instruments, so point-in-time constituent history has something to
-- hang off and benchmark-relative statistics have a benchmark.
INSERT INTO reference.instrument
  (symbol, venue_id, asset_class, name, currency, calendar_id, country_code, is_shortable)
SELECT d.symbol, (SELECT id FROM reference.venue WHERE code = 'XNYS'),
       'index', d.name, 'USD',
       (SELECT id FROM reference.calendar WHERE code = 'NYSE'), 'US', false
  FROM (VALUES
    ('SPX','S&P 500 Index'),
    ('NDX','Nasdaq-100 Index'),
    ('RUT','Russell 2000 Index'),
    ('VIX','CBOE Volatility Index')
  ) AS d(symbol, name)
ON CONFLICT DO NOTHING;

-- Crypto, on the 24x7 calendar. Fractionable with a much smaller tick.
INSERT INTO reference.instrument
  (symbol, venue_id, asset_class, name, currency, calendar_id, tick_size,
   is_fractionable, is_shortable, adv_30d, median_spread_bps)
SELECT d.symbol, (SELECT id FROM reference.venue WHERE code = 'BINANCE'),
       'crypto', d.name, 'USDT',
       (SELECT id FROM reference.calendar WHERE code = '24x7'),
       0.01, true, true, d.adv, d.spread
  FROM (VALUES
    ('BTCUSDT','Bitcoin / Tether',   25000.0, 1.0),
    ('ETHUSDT','Ethereum / Tether', 350000.0, 1.5),
    ('SOLUSDT','Solana / Tether',  2500000.0, 3.0)
  ) AS d(symbol, name, adv, spread)
ON CONFLICT DO NOTHING;

-- Effective-dated symbol history. Every instrument needs at least one row or
-- reference.resolve_symbol returns nothing, and the META rename is included
-- because it is the canonical case the point-in-time design exists for.
INSERT INTO reference.instrument_symbol (instrument_id, symbol, valid_from, reason)
SELECT i.id, i.symbol, coalesce(i.listed_on, DATE '1990-01-01'), 'listing'
  FROM reference.instrument i
ON CONFLICT DO NOTHING;

UPDATE reference.instrument_symbol
   SET valid_from = DATE '2022-06-09'
 WHERE symbol = 'META'
   AND instrument_id = (SELECT id FROM reference.instrument WHERE symbol = 'META');

INSERT INTO reference.instrument_symbol (instrument_id, symbol, valid_from, valid_to, reason)
SELECT id, 'FB', DATE '2012-05-18', DATE '2022-06-09', 'rename'
  FROM reference.instrument WHERE symbol = 'META'
ON CONFLICT DO NOTHING;

-- Vendor symbol mapping, so the ingestor can resolve a payload without a
-- vendor account configured.
INSERT INTO reference.instrument_vendor_map (vendor, vendor_symbol, instrument_id)
SELECT 'sim', i.symbol, i.id FROM reference.instrument i
ON CONFLICT DO NOTHING;
