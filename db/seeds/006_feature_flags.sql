-- Feature flags. Anything gating a money path is is_financial, which the
-- schema requires to carry an owner and an expiry so the flag set does not
-- silently become permanent architecture.
INSERT INTO platform.feature_flag
  (key, description, is_enabled, rollout_pct, is_financial, owner, expires_at, value)
VALUES
  ('live_trading',
   'Route orders to a real broker. Off by default; nothing that touches real capital ships enabled.',
   false, 0, true, 'platform-team', CURRENT_DATE + 365, NULL),
  ('options_chain',
   'Options chain, greeks and multi-leg order tickets.',
   true, 100, false, NULL, NULL, NULL),
  ('ml_signals',
   'Machine-learning signal generation in the quant engine.',
   true, 100, false, NULL, NULL, NULL),
  ('social_feed',
   'The social layer: feed, profiles, posts, groups.',
   true, 100, false, NULL, NULL, NULL),
  ('social_leaderboard',
   'Opt-in leaderboard ranked on risk-adjusted return.',
   false, 0, false, NULL, NULL, NULL),
  ('broker_aggregator',
   'Long-tail brokerage linking through an aggregation provider.',
   false, 0, true, 'platform-team', CURRENT_DATE + 180, NULL),
  ('auto_execute_signals',
   'Let a deployed strategy place orders without user confirmation.',
   false, 0, true, 'risk-team', CURRENT_DATE + 180, NULL),
  ('feed_ranking_weights',
   'Feed ranking coefficients. Tunable without a deploy; every scored request emits the component breakdown as span attributes.',
   true, 100, false, NULL, NULL,
   '{"recency":1.0,"affinity":0.8,"quality":0.6,"engagement":0.4,"rationale":0.3,
     "repetition_penalty":0.5,"report_penalty":1.2,"half_life_hours":6,
     "fanout_follower_ceiling":5000}'::jsonb),
  ('pretrade_fail_open_paper',
   'Allow paper orders through when the risk engine is unreachable. Live accounts always fail closed.',
   true, 100, true, 'risk-team', CURRENT_DATE + 365, NULL)
ON CONFLICT (key) DO UPDATE
  SET description = EXCLUDED.description, value = EXCLUDED.value;
