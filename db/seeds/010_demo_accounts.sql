-- Demo users and accounts. Passwords are the Argon2id hash of "helios-demo"
-- with the default parameters — these are local-development fixtures and the
-- seed refuses to run against anything but a local or docker environment.
DO $$
BEGIN
  IF current_setting('helios.environment', true) NOT IN ('local', 'docker', '')
     AND current_setting('helios.environment', true) IS NOT NULL THEN
    RAISE EXCEPTION 'demo account seed refuses to run outside local/docker (env=%)',
      current_setting('helios.environment', true);
  END IF;
END $$;

INSERT INTO identity."user"
  (id, email, display_name, status, email_verified_at, kyc_status,
   country_code, base_currency, risk_tolerance, timezone)
VALUES
  ('11111111-1111-4111-8111-111111111111', 'demo@helios.test',
   'Demo Trader', 'active', now(), 'approved', 'US', 'USD', 3, 'America/New_York'),
  ('22222222-2222-4222-8222-222222222222', 'quant@helios.test',
   'Systematic Sam', 'active', now(), 'approved', 'US', 'USD', 4, 'America/New_York'),
  ('33333333-3333-4333-8333-333333333333', 'ops@helios.test',
   'Desk Operator', 'active', now(), 'approved', 'US', 'USD', 2, 'UTC')
ON CONFLICT (id) DO NOTHING;

INSERT INTO identity.user_role (user_id, role_id)
SELECT u.id, r.id
  FROM identity."user" u, identity.role r
 WHERE (u.email = 'demo@helios.test'  AND r.key = 'trader')
    OR (u.email = 'quant@helios.test' AND r.key = 'pro')
    OR (u.email = 'ops@helios.test'   AND r.key = 'operator')
ON CONFLICT DO NOTHING;

INSERT INTO book.account
  (id, owner_user_id, name, account_type, status, base_currency, broker,
   is_paper, max_leverage, options_level, shorting_enabled, crypto_enabled, opened_at)
VALUES
  ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   'Demo Margin', 'margin', 'active', 'USD', 'internal_sim', true, 2, 2, true, true, now()),
  ('bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb', '22222222-2222-4222-8222-222222222222',
   'Systematic Book', 'portfolio_margin', 'active', 'USD', 'internal_sim', true, 4, 3, true, true, now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO book.portfolio (id, account_id, name, allocated_capital, is_default, benchmark_instrument_id)
SELECT 'cccccccc-1111-4111-8111-cccccccccccc', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
       'Core', 100000, true, (SELECT id FROM reference.instrument WHERE symbol = 'SPY')
ON CONFLICT (id) DO NOTHING;

INSERT INTO book.portfolio (id, account_id, name, allocated_capital, is_default, target_volatility, benchmark_instrument_id)
SELECT 'dddddddd-2222-4222-8222-dddddddddddd', 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb',
       'Momentum Sleeve', 250000, true, 0.15,
       (SELECT id FROM reference.instrument WHERE symbol = 'SPY')
ON CONFLICT (id) DO NOTHING;

-- Opening cash, posted through the ledger rather than written straight to the
-- balance: the balance is a projection, and seeding it directly would create
-- the exact drift the double-entry design exists to prevent.
INSERT INTO book.ledger_transaction (id, account_id, reason, idempotency_key, occurred_at, description)
VALUES
  ('eeeeeeee-1111-4111-8111-eeeeeeeeeeee', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
   'deposit', 'seed-open-demo', now(), 'Opening balance (demo seed)'),
  ('ffffffff-2222-4222-8222-ffffffffffff', 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb',
   'deposit', 'seed-open-quant', now(), 'Opening balance (demo seed)')
ON CONFLICT (idempotency_key) DO NOTHING;

INSERT INTO book.ledger_entry
  (transaction_id, account_id, ledger_account, amount, currency, occurred_at)
SELECT t.id, t.account_id, la.acct, la.amt, 'USD', t.occurred_at
  FROM book.ledger_transaction t
  CROSS JOIN LATERAL (VALUES
    ('cash'::book.ledger_account,
      CASE WHEN t.idempotency_key = 'seed-open-demo' THEN 100000 ELSE 250000 END::numeric),
    ('transfer_in'::book.ledger_account,
      CASE WHEN t.idempotency_key = 'seed-open-demo' THEN -100000 ELSE -250000 END::numeric)
  ) AS la(acct, amt)
 WHERE t.idempotency_key IN ('seed-open-demo', 'seed-open-quant')
   AND NOT EXISTS (SELECT 1 FROM book.ledger_entry e WHERE e.transaction_id = t.id);

INSERT INTO book.cash_balance (account_id, currency, settled, buying_power, day_trade_buying_power)
VALUES
  ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', 'USD', 100000, 200000, 400000),
  ('bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb', 'USD', 250000, 1000000, 1000000)
ON CONFLICT (account_id, currency) DO UPDATE SET settled = EXCLUDED.settled;

-- Risk limits, so the pre-trade gate has something real to evaluate on a
-- fresh install rather than approving everything by default.
INSERT INTO risk.limit_rule (scope, account_id, kind, enforcement, threshold, unit, currency, reason)
SELECT 'account', a.id, k.kind::risk.limit_kind, k.enf::risk.enforcement,
       k.thr, k.unit, 'USD', 'Default limit set by the demo seed'
  FROM book.account a
  CROSS JOIN (VALUES
    ('max_leverage',            'hard', 2.0,     'ratio'),
    ('max_position_pct_equity', 'hard', 0.25,    'ratio'),
    ('max_order_notional',      'hard', 50000,   'currency'),
    ('max_daily_loss',          'hard', 5000,    'currency'),
    ('max_drawdown',            'soft', 0.20,    'ratio'),
    ('max_position_pct_adv',    'soft', 0.05,    'ratio'),
    ('max_orders_per_minute',   'hard', 30,      'count')
  ) AS k(kind, enf, thr, unit)
 WHERE a.is_paper
ON CONFLICT DO NOTHING;

-- Watchlists and social profiles, so the first screen is not empty.
INSERT INTO notify.watchlist (id, user_id, name, is_default)
VALUES ('99999999-1111-4111-8111-999999999999',
        '11111111-1111-4111-8111-111111111111', 'Megacap Tech', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO notify.watchlist_item (watchlist_id, instrument_id, display_order)
SELECT '99999999-1111-4111-8111-999999999999', i.id,
       row_number() OVER (ORDER BY i.symbol)
  FROM reference.instrument i
 WHERE i.symbol IN ('AAPL','MSFT','NVDA','GOOGL','META','AMZN','TSLA')
ON CONFLICT DO NOTHING;

INSERT INTO social.profile
  (user_id, handle, display_name, bio, visibility, performance_disclosure,
   performance_portfolio_id, trading_styles, markets, track_record_start)
VALUES
  ('11111111-1111-4111-8111-111111111111', 'demotrader', 'Demo Trader',
   'Exploring Helios. Opinions are examples, not advice.',
   'public', 'returns_only', 'cccccccc-1111-4111-8111-cccccccccccc',
   '{discretionary,swing}', '{equity,etf}', CURRENT_DATE - 400),
  ('22222222-2222-4222-8222-222222222222', 'systematicsam', 'Systematic Sam',
   'Cross-sectional momentum and vol targeting. Everything backtested walk-forward.',
   'public', 'returns_only', 'dddddddd-2222-4222-8222-dddddddddddd',
   '{systematic,quant}', '{equity,etf,crypto}', CURRENT_DATE - 900)
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO social.follow (follower_id, followee_id, state, accepted_at)
VALUES ('11111111-1111-4111-8111-111111111111',
        '22222222-2222-4222-8222-222222222222', 'active', now())
ON CONFLICT DO NOTHING;
