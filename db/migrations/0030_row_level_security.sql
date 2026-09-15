-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0030 · Row-level security policies                                        ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- RLS is the SECOND line of defence. The gateway already authorises every
-- request; these policies exist because a single forgotten WHERE clause in one
-- resolver should not become a data breach. They are written to be boring and
-- uniform: a row is visible when it traces back to platform.current_user_id().
--
-- Service roles connect as helios_*, and the gateway issues
--   SET LOCAL helios.user_id = '…'
-- per transaction. An unset context yields NULL and therefore denies
-- everything, which is the correct failure direction.
--
-- Two deliberate exclusions:
--   • reference.*, market.*, fundamental.* carry no tenancy — they are shared
--     public data, and adding policies there would cost a filter on the
--     highest-volume reads in the system for no security benefit.
--   • Table owners bypass RLS. Migrations and admin tooling run as the owner;
--     services must NOT. FORCE ROW LEVEL SECURITY is set where a service could
--     plausibly own the table.

-- Helper: does the current user own this account (directly, or as its user)?
CREATE OR REPLACE FUNCTION platform.owns_account(p_account_id uuid)
  RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM book.account a
     WHERE a.id = p_account_id
       AND a.owner_user_id = platform.current_user_id()
  )
$$;

CREATE OR REPLACE FUNCTION platform.owns_portfolio(p_portfolio_id uuid)
  RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM book.portfolio p
      JOIN book.account a ON a.id = p.account_id
     WHERE p.id = p_portfolio_id
       AND a.owner_user_id = platform.current_user_id()
  )
$$;

COMMENT ON FUNCTION platform.owns_account IS
  'SECURITY DEFINER so the policy can read book.account even when the caller has no direct policy allowing it. search_path is pinned, which is what stops the classic SECURITY DEFINER hijack.';

-- ── identity ────────────────────────────────────────────────────────────────
ALTER TABLE identity.user            ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.credential      ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.mfa_factor      ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.session         ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.device          ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.api_key         ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.user_consent    ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_self ON identity.user
  USING (id = platform.current_user_id());
CREATE POLICY credential_self ON identity.credential
  USING (user_id = platform.current_user_id());
CREATE POLICY mfa_self ON identity.mfa_factor
  USING (user_id = platform.current_user_id());
CREATE POLICY session_self ON identity.session
  USING (user_id = platform.current_user_id());
CREATE POLICY device_self ON identity.device
  USING (user_id = platform.current_user_id());
CREATE POLICY api_key_self ON identity.api_key
  USING (user_id = platform.current_user_id());
CREATE POLICY consent_self ON identity.user_consent
  USING (user_id = platform.current_user_id());

-- ── book ────────────────────────────────────────────────────────────────────
ALTER TABLE book.account            ENABLE ROW LEVEL SECURITY;
ALTER TABLE book.portfolio          ENABLE ROW LEVEL SECURITY;
ALTER TABLE book.broker_connection  ENABLE ROW LEVEL SECURITY;
ALTER TABLE book.position           ENABLE ROW LEVEL SECURITY;
ALTER TABLE book.position_lot       ENABLE ROW LEVEL SECURITY;
ALTER TABLE book.cash_balance       ENABLE ROW LEVEL SECURITY;
ALTER TABLE book.ledger_transaction ENABLE ROW LEVEL SECURITY;
ALTER TABLE book.ledger_entry       ENABLE ROW LEVEL SECURITY;
ALTER TABLE book.transfer           ENABLE ROW LEVEL SECURITY;
ALTER TABLE book.equity_snapshot    ENABLE ROW LEVEL SECURITY;

CREATE POLICY account_owner ON book.account
  USING (owner_user_id = platform.current_user_id());
CREATE POLICY portfolio_owner ON book.portfolio
  USING (platform.owns_account(account_id));
CREATE POLICY broker_connection_owner ON book.broker_connection
  USING (platform.owns_account(account_id));
CREATE POLICY position_owner ON book.position
  USING (platform.owns_account(account_id));
CREATE POLICY position_lot_owner ON book.position_lot
  USING (platform.owns_account(account_id));
CREATE POLICY cash_balance_owner ON book.cash_balance
  USING (platform.owns_account(account_id));
CREATE POLICY ledger_transaction_owner ON book.ledger_transaction
  USING (platform.owns_account(account_id));
CREATE POLICY ledger_entry_owner ON book.ledger_entry
  USING (platform.owns_account(account_id));
CREATE POLICY transfer_owner ON book.transfer
  USING (platform.owns_account(account_id));
CREATE POLICY equity_snapshot_owner ON book.equity_snapshot
  USING (platform.owns_account(account_id));

-- ── oms ─────────────────────────────────────────────────────────────────────
ALTER TABLE oms.order        ENABLE ROW LEVEL SECURITY;
ALTER TABLE oms.order_event  ENABLE ROW LEVEL SECURITY;
ALTER TABLE oms.fill         ENABLE ROW LEVEL SECURITY;
ALTER TABLE oms.rejection    ENABLE ROW LEVEL SECURITY;
ALTER TABLE oms.algo_execution ENABLE ROW LEVEL SECURITY;

CREATE POLICY order_owner ON oms.order
  USING (platform.owns_account(account_id));
-- Order events have no account column; they inherit visibility from the order,
-- which is the only place the tenancy actually lives.
CREATE POLICY order_event_owner ON oms.order_event
  USING (EXISTS (SELECT 1 FROM oms.order o
                  WHERE o.id = order_event.order_id
                    AND platform.owns_account(o.account_id)));
CREATE POLICY fill_owner ON oms.fill
  USING (platform.owns_account(account_id));
CREATE POLICY rejection_owner ON oms.rejection
  USING (platform.owns_account(account_id));
CREATE POLICY algo_execution_owner ON oms.algo_execution
  USING (EXISTS (SELECT 1 FROM oms.order o
                  WHERE o.id = algo_execution.parent_order_id
                    AND platform.owns_account(o.account_id)));

-- ── research ────────────────────────────────────────────────────────────────
ALTER TABLE research.strategy   ENABLE ROW LEVEL SECURITY;
ALTER TABLE research.deployment ENABLE ROW LEVEL SECURITY;
ALTER TABLE research.backtest   ENABLE ROW LEVEL SECURITY;

-- A public strategy is readable by anyone; everything else is owner-only.
CREATE POLICY strategy_owner_or_public ON research.strategy
  USING (owner_user_id = platform.current_user_id() OR is_public);
CREATE POLICY deployment_owner ON research.deployment
  USING (platform.owns_portfolio(portfolio_id));
CREATE POLICY backtest_owner ON research.backtest
  USING (requested_by = platform.current_user_id());

-- ── risk ────────────────────────────────────────────────────────────────────
ALTER TABLE risk.limit_rule        ENABLE ROW LEVEL SECURITY;
ALTER TABLE risk.assessment        ENABLE ROW LEVEL SECURITY;
ALTER TABLE risk.breach            ENABLE ROW LEVEL SECURITY;
ALTER TABLE risk.portfolio_snapshot ENABLE ROW LEVEL SECURITY;

-- Desk-scoped limits have no account_id and are visible to operators only,
-- which the gateway expresses by not setting helios.user_id for desk reads.
CREATE POLICY limit_rule_owner ON risk.limit_rule
  USING (account_id IS NOT NULL AND platform.owns_account(account_id));
CREATE POLICY assessment_owner ON risk.assessment
  USING (platform.owns_account(account_id));
CREATE POLICY breach_owner ON risk.breach
  USING (platform.owns_account(account_id));
CREATE POLICY risk_snapshot_owner ON risk.portfolio_snapshot
  USING (platform.owns_account(account_id));

-- ── notify ──────────────────────────────────────────────────────────────────
ALTER TABLE notify.watchlist     ENABLE ROW LEVEL SECURITY;
ALTER TABLE notify.alert_rule    ENABLE ROW LEVEL SECURITY;
ALTER TABLE notify.notification  ENABLE ROW LEVEL SECURITY;
ALTER TABLE notify.preference    ENABLE ROW LEVEL SECURITY;

CREATE POLICY watchlist_owner_or_public ON notify.watchlist
  USING (user_id = platform.current_user_id() OR is_public);
CREATE POLICY alert_rule_owner ON notify.alert_rule
  USING (user_id = platform.current_user_id());
CREATE POLICY notification_owner ON notify.notification
  USING (user_id = platform.current_user_id());
CREATE POLICY preference_owner ON notify.preference
  USING (user_id = platform.current_user_id());

-- ── broker ──────────────────────────────────────────────────────────────────
ALTER TABLE broker.connection           ENABLE ROW LEVEL SECURITY;
ALTER TABLE broker.external_transaction ENABLE ROW LEVEL SECURITY;
ALTER TABLE broker.import_batch         ENABLE ROW LEVEL SECURITY;
ALTER TABLE broker.import_row           ENABLE ROW LEVEL SECURITY;
ALTER TABLE broker.manual_entry         ENABLE ROW LEVEL SECURITY;
ALTER TABLE broker.reconciliation       ENABLE ROW LEVEL SECURITY;

CREATE POLICY broker_connection_owner_rls ON broker.connection
  USING (user_id = platform.current_user_id());
CREATE POLICY external_transaction_owner ON broker.external_transaction
  USING (platform.owns_account(account_id));
CREATE POLICY import_batch_owner ON broker.import_batch
  USING (user_id = platform.current_user_id());
CREATE POLICY import_row_owner ON broker.import_row
  USING (EXISTS (SELECT 1 FROM broker.import_batch b
                  WHERE b.id = import_row.batch_id
                    AND b.user_id = platform.current_user_id()));
CREATE POLICY manual_entry_owner ON broker.manual_entry
  USING (user_id = platform.current_user_id());
CREATE POLICY reconciliation_owner ON broker.reconciliation
  USING (platform.owns_account(account_id));

-- ── social ──────────────────────────────────────────────────────────────────
-- The social policies are the ones that matter most: a missed filter here is a
-- privacy incident rather than an information leak between a user and
-- themselves. Blocks are enforced in the policy as well as in the query.
ALTER TABLE social.profile             ENABLE ROW LEVEL SECURITY;
ALTER TABLE social.post                ENABLE ROW LEVEL SECURITY;
ALTER TABLE social.post_attachment     ENABLE ROW LEVEL SECURITY;
ALTER TABLE social.follow              ENABLE ROW LEVEL SECURITY;
ALTER TABLE social.block               ENABLE ROW LEVEL SECURITY;
ALTER TABLE social.mute                ENABLE ROW LEVEL SECURITY;
ALTER TABLE social.bookmark            ENABLE ROW LEVEL SECURITY;
ALTER TABLE social.report              ENABLE ROW LEVEL SECURITY;
ALTER TABLE social.conversation_member ENABLE ROW LEVEL SECURITY;
ALTER TABLE social.message             ENABLE ROW LEVEL SECURITY;

CREATE POLICY profile_visible ON social.profile
  USING (social.can_view_profile(platform.current_user_id(), user_id));

-- A post is visible when: it is yours; or it is public and neither party has
-- blocked the other and it is not removed; or it is followers-only and you
-- follow the author.
CREATE POLICY post_visible ON social.post
  USING (
    author_id = platform.current_user_id()
    OR (
      deleted_at IS NULL
      AND moderation_state <> 'removed'
      AND NOT social.is_blocked_between(platform.current_user_id(), author_id)
      AND (
        visibility = 'public'
        OR EXISTS (SELECT 1 FROM social.follow f
                    WHERE f.follower_id = platform.current_user_id()
                      AND f.followee_id = post.author_id
                      AND f.state = 'active')
      )
    )
  );

CREATE POLICY post_attachment_visible ON social.post_attachment
  USING (EXISTS (SELECT 1 FROM social.post p WHERE p.id = post_attachment.post_id));

CREATE POLICY follow_participant ON social.follow
  USING (follower_id = platform.current_user_id()
         OR followee_id = platform.current_user_id());
CREATE POLICY block_owner ON social.block
  USING (blocker_id = platform.current_user_id());
CREATE POLICY mute_owner ON social.mute
  USING (muter_id = platform.current_user_id());
CREATE POLICY bookmark_owner ON social.bookmark
  USING (user_id = platform.current_user_id());

-- Reporters can see their own reports. Nothing here lets a reported user see
-- who reported them — that is the whole point of the table's design.
CREATE POLICY report_reporter ON social.report
  USING (reporter_id = platform.current_user_id());

CREATE POLICY conversation_member_self ON social.conversation_member
  USING (user_id = platform.current_user_id());
CREATE POLICY message_participant ON social.message
  USING (EXISTS (SELECT 1 FROM social.conversation_member cm
                  WHERE cm.conversation_id = message.conversation_id
                    AND cm.user_id = platform.current_user_id()
                    AND cm.left_at IS NULL));

COMMENT ON POLICY post_visible ON social.post IS
  'Block enforcement lives here as well as in the query layer. A resolver that forgets the block filter still returns nothing, which converts a privacy incident into a missing-results bug.';

-- ── Grants ──────────────────────────────────────────────────────────────────
-- Services get DML on the schemas they own and SELECT on shared reference
-- data. RLS then narrows those grants per row.
DO $$
DECLARE
  r text;
  shared constant text[] := ARRAY['reference', 'market', 'fundamental'];
  s text;
BEGIN
  FOREACH r IN ARRAY ARRAY[
    'helios_gateway', 'helios_marketdata', 'helios_quant',
    'helios_risk', 'helios_execution', 'helios_notify'
  ] LOOP
    FOREACH s IN ARRAY shared LOOP
      EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', s, r);
      EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', s, r);
    END LOOP;
    EXECUTE format('GRANT USAGE ON SCHEMA platform TO %I', r);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA platform TO %I', r);
  END LOOP;

  -- The gateway is the only role that touches user-facing schemas directly.
  FOREACH s IN ARRAY ARRAY['identity', 'book', 'oms', 'research', 'risk',
                           'notify', 'social', 'broker'] LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO helios_gateway', s);
    EXECUTE format(
      'GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA %I TO helios_gateway', s);
  END LOOP;

  -- Write paths for the services that own them.
  EXECUTE 'GRANT USAGE ON SCHEMA market TO helios_marketdata';
  EXECUTE 'GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA market TO helios_marketdata';
  EXECUTE 'GRANT USAGE ON SCHEMA oms, book TO helios_execution';
  EXECUTE 'GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA oms TO helios_execution';
  EXECUTE 'GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA book TO helios_execution';
  EXECUTE 'GRANT USAGE ON SCHEMA risk TO helios_risk';
  EXECUTE 'GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA risk TO helios_risk';
  EXECUTE 'GRANT USAGE ON SCHEMA research TO helios_quant';
  EXECUTE 'GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA research TO helios_quant';
  EXECUTE 'GRANT USAGE ON SCHEMA notify TO helios_notify';
  EXECUTE 'GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA notify TO helios_notify';
END $$;

-- Service roles must not bypass RLS even on tables they may come to own.
DO $$
DECLARE t record;
BEGIN
  FOR t IN
    SELECT n.nspname AS schema_name, c.relname AS table_name
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relrowsecurity
       AND c.relkind = 'r'
  LOOP
    EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY',
                   t.schema_name, t.table_name);
  END LOOP;
END $$;
