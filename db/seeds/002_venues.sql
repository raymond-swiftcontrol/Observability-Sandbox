-- Venues with the microstructure facts the execution and backtest models read.
-- US equity settlement is T+1 since May 2024; fee figures are indicative
-- retail-facing rates, not a rate card.
INSERT INTO reference.venue
  (mic, code, name, kind, country_code, timezone, currency,
   lot_size, maker_fee_bps, taker_fee_bps, settlement_days,
   has_pre_market, has_post_market, is_24h, tick_size_regime)
VALUES
  ('XNAS','XNAS','Nasdaq Stock Market','exchange','US','America/New_York','USD',
   1, -0.20, 0.30, 1, true, true, false,
   '[{"max_price":1,"tick":0.0001},{"max_price":null,"tick":0.01}]'::jsonb),
  ('XNYS','XNYS','New York Stock Exchange','exchange','US','America/New_York','USD',
   1, -0.15, 0.27, 1, true, true, false,
   '[{"max_price":1,"tick":0.0001},{"max_price":null,"tick":0.01}]'::jsonb),
  ('ARCX','ARCX','NYSE Arca','exchange','US','America/New_York','USD',
   1, -0.20, 0.30, 1, true, true, false,
   '[{"max_price":1,"tick":0.0001},{"max_price":null,"tick":0.01}]'::jsonb),
  ('BATS','BATS','Cboe BZX','exchange','US','America/New_York','USD',
   1, -0.20, 0.30, 1, true, true, false,
   '[{"max_price":1,"tick":0.0001},{"max_price":null,"tick":0.01}]'::jsonb),
  ('IEXG','IEXG','Investors Exchange','exchange','US','America/New_York','USD',
   1, 0.00, 0.09, 1, true, true, false,
   '[{"max_price":1,"tick":0.0001},{"max_price":null,"tick":0.01}]'::jsonb),
  ('XCBO','OPRA','Cboe Options Exchange','exchange','US','America/New_York','USD',
   1, 0.00, 0.00, 1, false, false, false,
   '[{"max_price":3,"tick":0.01},{"max_price":null,"tick":0.05}]'::jsonb),
  ('XCME','CME','Chicago Mercantile Exchange','exchange','US','America/Chicago','USD',
   1, 0.00, 0.00, 1, false, false, false, '[]'::jsonb),
  ('XLON','XLON','London Stock Exchange','exchange','GB','Europe/London','GBP',
   1, 0.00, 0.50, 2, false, false, false, '[]'::jsonb),
  ('XETR','XETR','Xetra','exchange','DE','Europe/Berlin','EUR',
   1, 0.00, 0.50, 2, false, false, false, '[]'::jsonb),
  ('XTKS','XTKS','Tokyo Stock Exchange','exchange','JP','Asia/Tokyo','JPY',
   100, 0.00, 0.50, 2, false, false, false, '[]'::jsonb),
  (NULL,'BINANCE','Binance','crypto_cex','MT','UTC','USDT',
   1, 1.00, 1.00, 0, false, false, true, '[]'::jsonb),
  (NULL,'COINBASE','Coinbase Exchange','crypto_cex','US','UTC','USD',
   1, 0.40, 0.60, 0, false, false, true, '[]'::jsonb),
  (NULL,'SIM','Helios Simulator','exchange','US','America/New_York','USD',
   1, 0.00, 0.00, 1, true, true, false,
   '[{"max_price":1,"tick":0.0001},{"max_price":null,"tick":0.01}]'::jsonb)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, settlement_days = EXCLUDED.settlement_days;
