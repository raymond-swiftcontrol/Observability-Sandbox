-- Reference currencies. minor_units drives rounding everywhere money is
-- displayed or settled, so getting JPY (0) and the crypto entries right
-- matters more than the list being exhaustive.
INSERT INTO reference.currency (code, name, minor_units, symbol, is_crypto) VALUES
  ('USD', 'US Dollar',            2, '$',   false),
  ('EUR', 'Euro',                 2, '€',   false),
  ('GBP', 'Pound Sterling',       2, '£',   false),
  ('JPY', 'Japanese Yen',         0, '¥',   false),
  ('CHF', 'Swiss Franc',          2, 'Fr',  false),
  ('CAD', 'Canadian Dollar',      2, 'C$',  false),
  ('AUD', 'Australian Dollar',    2, 'A$',  false),
  ('HKD', 'Hong Kong Dollar',     2, 'HK$', false),
  ('SGD', 'Singapore Dollar',     2, 'S$',  false),
  ('BTC', 'Bitcoin',              8, '₿',   true),
  ('ETH', 'Ether',               18, 'Ξ',   true),
  ('USDT','Tether',               6, '₮',   true),
  ('USDC','USD Coin',             6, NULL,  true)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, minor_units = EXCLUDED.minor_units;
