-- Roles and permissions. requires_step_up marks the actions that need a fresh
-- MFA assertion — everything that moves money or changes a risk limit.
INSERT INTO identity.permission (key, resource, action, description, requires_step_up) VALUES
  ('instrument:read',   'instrument', 'read',   'Search and view instruments',            false),
  ('marketdata:read',   'marketdata', 'read',   'Quotes, bars, books, option chains',     false),
  ('portfolio:read',    'portfolio',  'read',   'View positions, balances, P&L',          false),
  ('portfolio:write',   'portfolio',  'write',  'Create and edit portfolios',             false),
  ('order:preview',     'order',      'preview','Price an order without submitting',      false),
  ('order:submit',      'order',      'submit', 'Submit an order',                        true),
  ('order:cancel',      'order',      'cancel', 'Cancel a working order',                 false),
  ('transfer:create',   'transfer',   'create', 'Move cash in or out',                    true),
  ('broker:link',       'broker',     'link',   'Connect a brokerage account',            true),
  ('broker:read',       'broker',     'read',   'View connections and sync status',       false),
  ('strategy:read',     'strategy',   'read',   'View strategies',                        false),
  ('strategy:write',    'strategy',   'write',  'Create and edit strategies',             false),
  ('strategy:deploy',   'strategy',   'deploy', 'Deploy a strategy to a live portfolio',  true),
  ('backtest:run',      'backtest',   'run',    'Run backtests and sweeps',               false),
  ('risk:read',         'risk',       'read',   'View risk metrics and limits',           false),
  ('risk:write',        'risk',       'write',  'Change risk limits',                     true),
  ('killswitch:toggle', 'killswitch', 'toggle', 'Activate or release the kill switch',    true),
  ('social:read',       'social',     'read',   'View the feed and profiles',             false),
  ('social:write',      'social',     'write',  'Post, reply, react',                     false),
  ('social:moderate',   'social',     'moderate','Review reports and take action',        true),
  ('admin:read',        'admin',      'read',   'Operator console read access',           false),
  ('admin:write',       'admin',      'write',  'Operator console write access',          true)
ON CONFLICT (key) DO NOTHING;

INSERT INTO identity.role (key, name, description, is_system) VALUES
  ('trader',    'Trader',          'Standard retail user',                        true),
  ('pro',       'Professional',    'Higher limits, options level 3+, API access', true),
  ('readonly',  'Read Only',       'View without trading — demo and audit',       true),
  ('moderator', 'Moderator',       'Social moderation queue',                     true),
  ('operator',  'Desk Operator',   'Console, reconciliation, kill switch',        true),
  ('admin',     'Administrator',   'Full platform access',                        true)
ON CONFLICT (key) DO NOTHING;

-- trader: everything a retail user needs, minus moderation and admin.
INSERT INTO identity.role_permission (role_id, permission_id)
SELECT r.id, p.id FROM identity.role r, identity.permission p
 WHERE r.key = 'trader'
   AND p.key IN ('instrument:read','marketdata:read','portfolio:read','portfolio:write',
                 'order:preview','order:submit','order:cancel','transfer:create',
                 'broker:link','broker:read','strategy:read','strategy:write',
                 'strategy:deploy','backtest:run','risk:read','risk:write',
                 'killswitch:toggle','social:read','social:write')
ON CONFLICT DO NOTHING;

INSERT INTO identity.role_permission (role_id, permission_id)
SELECT r.id, p.id FROM identity.role r, identity.permission p
 WHERE r.key = 'pro'
ON CONFLICT DO NOTHING;

INSERT INTO identity.role_permission (role_id, permission_id)
SELECT r.id, p.id FROM identity.role r, identity.permission p
 WHERE r.key = 'readonly'
   AND p.key IN ('instrument:read','marketdata:read','portfolio:read',
                 'order:preview','strategy:read','risk:read','social:read')
ON CONFLICT DO NOTHING;

INSERT INTO identity.role_permission (role_id, permission_id)
SELECT r.id, p.id FROM identity.role r, identity.permission p
 WHERE r.key = 'moderator'
   AND p.key IN ('social:read','social:write','social:moderate','admin:read')
ON CONFLICT DO NOTHING;

INSERT INTO identity.role_permission (role_id, permission_id)
SELECT r.id, p.id FROM identity.role r, identity.permission p
 WHERE r.key = 'operator'
   AND p.key IN ('instrument:read','marketdata:read','portfolio:read','risk:read',
                 'risk:write','killswitch:toggle','admin:read','admin:write','broker:read')
ON CONFLICT DO NOTHING;

INSERT INTO identity.role_permission (role_id, permission_id)
SELECT r.id, p.id FROM identity.role r, identity.permission p WHERE r.key = 'admin'
ON CONFLICT DO NOTHING;

-- Disclosures gating live trading and options, so the consent trail exists
-- from the first run rather than being retrofitted.
INSERT INTO identity.disclosure (key, version, title, body_url, required_for) VALUES
  ('terms',            'v1', 'Terms of Service',            '/legal/terms',    '{}'),
  ('privacy',          'v1', 'Privacy Policy',              '/legal/privacy',  '{}'),
  ('market_risk',      'v1', 'Market Risk Disclosure',      '/legal/risk',     '{live_trading}'),
  ('options_risk',     'v1', 'Characteristics and Risks of Standardized Options',
                                                            '/legal/options',  '{options}'),
  ('margin_risk',      'v1', 'Margin Risk Disclosure',      '/legal/margin',   '{margin}'),
  ('not_advice',       'v1', 'Helios Does Not Provide Investment Advice',
                                                            '/legal/no-advice','{live_trading,social}'),
  ('backtest_caveat',  'v1', 'Backtested Performance Disclosure',
                                                            '/legal/backtest', '{backtest_sharing}')
ON CONFLICT (key, version) DO NOTHING;
